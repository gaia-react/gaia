#!/usr/bin/env bash
# PreToolUse Bash hook: block commits to main/master and force-push to main/master,
# and block a peer session moving the main checkout's HEAD off a branch another
# session holds there with an open pull request.
#
# Command-position anchoring: the rules fire only when `git` is the command word
# of a pipeline segment (start of command, after a `| & ; ( )` separator, or
# after an env-var prefix), a real `git commit` / `git push` INVOCATION.
# Command TEXT that merely contains the words (a grep pattern, an echo string,
# a path, an argument to another program such as `grep -n -e git commit file`)
# is not an invocation and never fires.
#
# Two shapes of text are an exception, because the walk splits on separators
# without modelling quoting. Text whose own segment begins with a `cd` this
# guard cannot read, carrying a `git commit` or `git push` word after it; and
# text whose own segment begins with the `git` word itself carrying a `-C`
# this guard cannot read. Either reads as an invocation, and the ambiguity arm
# makes it deny from any checkout. The branch-dir block below records what that
# costs and what to do about it.
#
# Policy: wiki/concepts/Git Workflow.md; the hop guard enforces the main-checkout
# precondition in wiki/concepts/PR Merge Workflow.md.
set -euo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literals below satisfy, live in .claude/hooks/lib/jq-availability.sh.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-main-destructive-git.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the main-branch destructive-git guard' "$payload" tool_input 'git'

cmd=$(echo "$payload" | jq -r '.tool_input.command // empty')

# Only act on git commands, short-circuit everything else. (Fast path only;
# correctness comes from the command-position scan below.)
[[ "$cmd" =~ (^|[[:space:]&;|()])git([[:space:]]|$) ]] || exit 0

# Repo-scope: this repo's main-branch policy governs this repo only. A git
# command aimed at a different repo (e.g. `git -C ../other push origin main`
# or `cd ../other && git push`) is out of scope, allow it. Fail-closed: any
# ambiguity falls through and the policy still enforces.
#
# Bracketed in `set +e` because errexit is armed above. An unparseable copy (an
# unresolved merge conflict, a truncated write) would otherwise abandon the shell
# before the `type` check below can degrade, and that exit is 2 -- the deny code --
# refusing every matching call including the edit that would repair the library.
# Suspending errexit for the one command lets the `type` check do the degrading, at
# no fork and at any source depth. `bash -n` cannot: it does not recurse.
#
# Rooted at this file's own on-disk location, never at the process working
# directory. A bare `.claude/hooks/lib/repo-scope.sh` test is false from
# anywhere below the repository root, and the `type` degrade below cannot tell
# that from a missing library: the foreign-repo carve-out would be lost and a
# `-C`-scoped push at a different repository denied with a message about this
# one's `main`.
#
# Resolved through the ANCESTOR (`../..`) rather than through a `lib` child, the
# same way the main-root load below resolves, and deliberately: a hook's own
# directory was read to run it and an ancestor of it contains it, so this
# substitution has no reachable failure to degrade from, while one that changes
# directory into a lib child does.
# gaia:maintainer-only:start
# That warrant covers this ancestor resolve alone, and not the file. The hook is
# a DRIVEN member of the lib-degrade suite in
# .gaia/tests/hooks/audit-hook-lib-degrade.bats, reached through the
# jq-availability load above, which does resolve a `lib` child. That suite
# derives its membership from the hooks themselves and is the authority on which
# side of its table this file sits, so the answer is not restated here: a
# restatement nothing couples to that suite is how the claim this replaces went
# stale, and a corrected one would start the same decay again.
# gaia:maintainer-only:end
_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _hook_root=''
_scope_lib="$_hook_root/.claude/hooks/lib/repo-scope.sh"
set +e; [ -n "$_hook_root" ] && [ -f "$_scope_lib" ] && . "$_scope_lib" 2>/dev/null; set -e
#
# A verdict for the commit and push rules only, never for the hop guard below.
# The helper answers "same repository", and every linked worktree of THIS
# repository is the same repository. The hop guard asks a narrower question,
# whether the target is the main checkout itself, so it makes its own test.
foreign_repo=0
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  foreign_repo=1
fi

# The shared main-root resolver, sourced from this hook's own on-disk location
# (never cwd): the setup-in-progress sentinel below is main-anchored machine
# state (.gaia/state-registry.json scope=main-only), not a property of
# whichever tree this hook happens to run in. A load or resolve failure here
# must not weaken this guard's deny logic below, so it falls back to the prior
# bare-relative (process-cwd) derivation rather than exiting -- this guard is
# fail-closed on ambiguity, never fail-open.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || true
# The `|| true` arm is not enough on stock bash 3.2: an unparseable lib abandons
# the shell before the arm on that line runs. Same errexit bracket as the
# repo-scope load above, for the same reason.
set +e
if [ -n "${gaia_scripts:-}" ] && [ -f "$gaia_scripts/.gaia/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$gaia_scripts/.gaia/scripts/main-root-lib.sh" 2>/dev/null
fi
set -e
main_root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  main_root="$(gaia_resolve_main_root 2>/dev/null)" || main_root=""
fi
[ -n "$main_root" ] || main_root="$PWD"

# Setup standdown: while /setup-gaia provisions a greenfield repo it lands
# GAIA's own known-safe CI-install commit directly on main (main is not yet a
# collaboration surface and the commit has nothing to audit). setup-gaia
# creates this machine-local sentinel around that single commit+push and
# removes it right after, suspending the PR-only policy only for that window.
# The sentinel lives in .gaia/local/ (gitignored), so it never rides along in a
# teammate's clone: a fresh checkout always has this hook fully enforcing. The
# resting state is ON; this is the one explicit, temporary exception.
#
# Self-healing freshness bound: the sentinel is honored only while its mtime is
# within the last 10 minutes. The finalize commit+push completes in seconds, so
# a live setup is always inside that window; a sentinel a crashed or killed
# setup left behind goes stale on its own and enforcement resumes WITHOUT
# waiting for a /setup-gaia re-run to remove it. `find` returning empty (stale,
# missing, or unreadable) falls through to full enforcement, fail-closed.
if [ -f "$main_root/.gaia/local/setup-in-progress" ] \
   && [ -n "$(find "$main_root/.gaia/local/setup-in-progress" -mmin -10 2>/dev/null)" ]; then
  exit 0
fi

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

current_branch() {
  local cwd="$1"
  if [[ -n "$cwd" ]]; then
    git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || echo ""
  else
    git symbolic-ref --short HEAD 2>/dev/null || echo ""
  fi
}

# resolve_dir_kind <dir>: classify a directory WORD the command scan produced,
# and print the classification. One of:
#
#   same <dir>      the word names THIS repository
#   foreign <dir>   the word names a readable directory inside ANOTHER
#                   repository
#   unknown         the word names no readable repository at all: it carries a
#                   variable or a substitution the scan cannot expand, it
#                   points nowhere, or there is no resolver to ask
#
# Both readable answers carry <dir> in its tilde-expanded form, which is what a
# caller reads a branch out of. A caller that read the raw word instead would
# resolve a tilde path here and then read a branch out of the literal `~`
# spelling, which answers nothing and allows.
#
# Always succeeds, so a caller assigning its output under errexit is not
# abandoned by a directory that does not resolve.
#
# Three answers rather than two, because the two non-`same` cases are
# different questions and only one of them is unanswerable. `unknown` is what
# this guard fails closed on: the checkout the segment acts in is genuinely
# undecided, so the rules below test every candidate it could be. `foreign` is
# decided, the word expanded and simply named another repository, and
# collapsing it into `unknown` denied a sibling-repository commit against THIS
# checkout's branch whenever a home command shared the tool call, since the
# foreign stand-down below is a WHOLE-CALL verdict and answers home there.
# What each caller then does with a `foreign` word is what it did before the
# ambiguity arm existed; the classification is the only thing restored here.
resolve_dir_kind() {
  local dir="$1" a b
  [ -n "$dir" ] || { printf 'unknown'; return 0; }
  # The tilde arrives as a literal character, never expanded, because it reached
  # this hook as text inside the tool call rather than through a shell. SC2088
  # fires on the quoted tilde, but these are case PATTERNS matching that literal
  # character, not an expansion attempt.
  # shellcheck disable=SC2088
  case "$dir" in
    '~') dir="$HOME" ;;
    '~/'*) dir="$HOME/${dir:2}" ;;
  esac
  command -v gaia_resolve_common_dir >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  a=$(gaia_resolve_common_dir "$dir" 2>/dev/null) || { printf 'unknown'; return 0; }
  [ -n "$a" ] || { printf 'unknown'; return 0; }
  b=$(gaia_resolve_common_dir 2>/dev/null) || { printf 'unknown'; return 0; }
  if [ -n "$b" ] && [ "$a" = "$b" ]; then
    printf 'same %s' "$dir"
  else
    printf 'foreign %s' "$dir"
  fi
  return 0
}

# ambiguous_main_branch: print main or master when a checkout the acting
# segment could be standing in, but which a directory word left unresolved,
# is on one of them; print nothing otherwise. Always succeeds, so a caller
# assigning its output under errexit is never abandoned.
#
# Two candidates. This hook's own working directory is where the shell stands
# when no `cd` moved it, or when one moved it back. The main checkout is where
# an unreadable word most often points FROM a linked worktree, which is the
# ordinary session shape here: neither the tracked directory nor this hook's
# own is that checkout from inside a worktree, so without it every
# `cd "$SOMEWHERE" && git commit` spelled there reads a branch that is not the
# one the commit lands on, which is the whole failure this flag exists for.
#
# The segment's own directory is not retested here: the caller tests it, and
# whenever this function is consulted it holds the same value the tracked `cd`
# does, so a third probe would spend a subprocess to ask a settled question.
ambiguous_main_branch() {
  local b
  b=$(current_branch "")
  if [ "$b" = main ] || [ "$b" = master ]; then
    printf '%s' "$b"
    return 0
  fi
  b=$(current_branch "$main_root")
  if [ "$b" = main ] || [ "$b" = master ]; then
    printf '%s' "$b"
  fi
  return 0
}

# cmd_has_unquoted_group <string>: 0 when the command carries a `(` or `)`
# outside quotes.
#
# A `cd` inside a subshell moves nothing once the group closes, and the segment
# walk below splits on those characters without recording which one it split at,
# so a tracked `cd` cannot be scoped to the group it belongs to. Tracking stands
# down for the whole command instead, leaving every segment read against this
# hook's own working directory.
#
# Quoting is modelled rather than pattern-matched because the distinction is
# load-bearing: a parenthesis inside a quoted value is ordinary text, and a
# commit subject routinely carries one, so a test that merely looked for the
# character would stand tracking down on an ordinary commit and deny it.
#
# What the stand-down reaches beyond a real subshell is an ordinary unquoted
# command substitution, which carries the same characters: a `cd` into a linked
# worktree followed by a push whose refspec comes from one is read against this
# hook's own working directory rather than the worktree's, and denied. That is a
# false deny rather than a miss, and the escape is running the command with the
# `!` prefix.
#
# The leading `case` is a fast path for the ordinary command that carries no
# parenthesis at all, which keeps the character walk off every invocation.
cmd_has_unquoted_group() {
  local s="$1" BLOCK=256 base=0 n_s block n_b k c q="" esc=0
  case "$s" in
    *'('* | *')'*) ;;
    *) return 1 ;;
  esac
  n_s=${#s}
  while [ "$base" -lt "$n_s" ]; do
    block="${s:$base:$BLOCK}"
    base=$((base + BLOCK))
    k=0
    n_b=${#block}
    while [ "$k" -lt "$n_b" ]; do
      c="${block:$k:1}"
      k=$((k + 1))
      if [ "$esc" = 1 ]; then esc=0; continue; fi
      if [ "$c" = "\\" ] && [ "$q" != "'" ]; then esc=1; continue; fi
      if [ -n "$q" ]; then
        [ "$c" = "$q" ] && q=""
        continue
      fi
      case "$c" in
        '"' | "'") q="$c" ;;
        '(' | ')') return 0 ;;
      esac
    done
  done
  return 1
}

# split_git_words <string>: split one segment into shell-like words in the
# array `w`, modelling quoting the way the shell does -- a quote opens a span in
# which whitespace is ordinary text, and a backslash escapes the character after
# it -- and handing the words back unquoted.
#
# `read -ra` splits on whitespace alone, so a quoted global-option value
# carrying whitespace arrived as fragments and the fragment after the space
# landed in the slot the subcommand is read from, leaving every rule armed on
# git_sub reading a subcommand that was never spelled (gaia-react/gaia#2020).
#
# A word accumulates into `chunk` and reaches `word` once per block rather than
# once per character, and the walk indexes inside a block rather than into the
# whole string. `word="$word$c"` costs O(word) and a quoted span has no length
# bound, so a multi-kilobyte commit message made the naive walk quadratic: a
# synchronous stall on a blocking hook, at a size an ordinary `-m` body reaches.
split_git_words() {
  local s="$1" NL=$'\n' TAB=$'\t'
  local BLOCK=256 base=0 n_s block n_b k c
  local q="" esc=0 word="" chunk="" have=0
  w=()
  n_s=${#s}
  while [ "$base" -lt "$n_s" ]; do
    block="${s:$base:$BLOCK}"
    base=$((base + BLOCK))
    k=0
    n_b=${#block}
    while [ "$k" -lt "$n_b" ]; do
      c="${block:$k:1}"
      k=$((k + 1))
      if [ "$esc" = 1 ]; then esc=0; chunk="$chunk$c"; have=1; continue; fi
      # A backslash is literal inside single quotes, as in the shell itself.
      if [ "$c" = "\\" ] && [ "$q" != "'" ]; then esc=1; continue; fi
      if [ -n "$q" ]; then
        if [ "$c" = "$q" ]; then q=""; else chunk="$chunk$c"; fi
        have=1
        continue
      fi
      case "$c" in
        '"' | "'") q="$c"; have=1 ;;
        ' ' | "$TAB" | "$NL")
          [ "$have" = 1 ] && w+=("$word$chunk")
          word=""; chunk=""; have=0 ;;
        *) chunk="$chunk$c"; have=1 ;;
      esac
    done
    word="$word$chunk"
    chunk=""
  done
  [ "$have" = 1 ] && w+=("$word$chunk")
  return 0
}

# parse_git_globals <segment>: split one segment's git invocation at its
# subcommand. Only a `-C` between `git` and the subcommand word is git's own
# directory option. Past the subcommand it belongs to the subcommand
# (`git switch -C <branch>`, `git commit -C <commit>`) and names no directory,
# and reading it as one aimed every check at a directory named for a branch or
# a commit, so both of those passed. Sets git_cwd (the last global `-C` path, so
# `git -C <a> -C <b> commit` cannot slip past the commit and push rules on the
# first one), norm (the segment minus its global `-C` pairs, for the commit and
# push regexes), git_sub (the subcommand word), and git_args (the words after
# it).
#
# Honest limits, and they bind every rule armed on git_sub below rather than any
# one of them. These spellings reach the subcommand slot carrying something
# other than the subcommand, so the guard reads no subcommand and allows:
#
#   - a value-taking global option absent from the table below, whose value is a
#     bare word. The table mirrors the options git itself takes a separated
#     value for, and one missing from it hands its own value to the slot.
#   - a separator, a quote, or a value produced by an expansion (`$VAR`,
#     `$(...)`, a backtick, `~`), which is ordinary word text to a scan that
#     models quoting but does not expand.
#   - a quoted value carrying one of the `| & ; ( )` characters the segment walk
#     below cuts on, since that cut happens before this parser sees the segment.
#
# Closing any of them needs the shell's own evaluation of the command, which a
# PreToolUse hook reading `tool_input.command` as text does not have.
parse_git_globals() {
  local -a w kept
  local i=0 n t globals=0
  git_cwd="" git_sub=""
  git_args=()
  split_git_words "$1"
  n=${#w[@]}
  while [ "$i" -lt "$n" ]; do
    t="${w[$i]}"
    if [ "$globals" -eq 1 ]; then
      case "$t" in
        -C) git_cwd="${w[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
        # Every global git takes a SEPARATED value for. An option missing here
        # falls to the `-*` arm and its value reaches the catch-all that assigns
        # the subcommand, which is the disarm, so this table tracking git's own
        # is what keeps the arming honest. The `=`-joined spellings need no
        # entry: they are one word, so the subcommand still lands next.
        # `--exec-path` is deliberately absent: without `=` it takes no value,
        # git prints its exec path and exits, and nothing after it runs.
        -c | --git-dir | --work-tree | --namespace | --config-env | --attr-source)
          kept+=("$t" "${w[$((i + 1))]:-}"); i=$((i + 2)); continue ;;
        -*) ;;
        *) globals=2; git_sub="$t"; git_args=("${w[@]:$((i + 1))}") ;;
      esac
    elif [ "$globals" -eq 0 ] && [ "$t" = git ]; then
      globals=1
    fi
    kept+=("$t")
    i=$((i + 1))
  done
  norm=""
  [ "${#kept[@]}" -eq 0 ] || norm="${kept[*]}"
}

# push_refspec_names_main: 0 when the words after a `push` subcommand carry a
# refspec whose SOURCE is main, master, or HEAD. It reads the operands rather
# than a fixed position: the ref was pinned to the word after the remote, so an
# option written ahead of the remote shifted both and the push was allowed
# (gaia-react/gaia#2021). Rule 2 below still caught the shape when a force flag
# was present, which is what left the plain push as the hole.
#
# The first operand is the remote and every operand after it is a refspec, so a
# push naming several is read whole rather than at its first one. A `--` ends
# git's option parsing and is not itself an operand. A leading `+` on a refspec
# is the force marker and is not part of the ref name.
#
# Honest limits. An option absent from the value-taking table below leaves its
# value read as an operand, which shifts the remote and every refspec after it;
# where that value happens to spell a branch the result is a false deny rather
# than a false allow, which is the safe direction for a guard whose escape is
# running the command with the `!` prefix. A refspec naming main only as its
# DESTINATION (`feature:main`) is not read here: that is the reading this rule
# has always had, and narrowing or widening it is a separate question from where
# the ref sits.
push_refspec_names_main() {
  local t seen_remote=0 skip_next=0 ref
  for t in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$t" in
      --) continue ;;
      -o | --push-option | --repo | --receive-pack | --exec)
        skip_next=1; continue ;;
      -*) continue ;;
    esac
    if [ "$seen_remote" -eq 0 ]; then seen_remote=1; continue; fi
    ref="${t#+}"
    case "$ref" in
      HEAD | main | master) return 0 ;;
      HEAD:* | main:* | master:*) return 0 ;;
    esac
  done
  return 1
}

# --- main-checkout hop guard -------------------------------------------------
#
# Several sessions share one main checkout: one can hold it on its own branch
# mid-audit while worktree sessions merge around it, and the feature-branch
# cleanup's `git checkout main` then yanks that HEAD away and forfeits the
# holder's audit round. Prose asking the next session to read HEAD first did not
# hold, so the move is denied here. It is a safety net behind that prose rather
# than a gate: anything it cannot check fails open, with one stderr line.

# The directory a git segment acts on: its last global `-C` path (resolved
# against the payload's cwd when relative), else the payload's cwd, else this
# process's.
hop_target() {
  local dir="$1" base
  base=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null) || base=""
  [ -n "$base" ] || base="$PWD"
  case "$dir" in
    \"*\") dir="${dir#\"}"; dir="${dir%\"}" ;;
    \'*\') dir="${dir#\'}"; dir="${dir%\'}" ;;
  esac
  case "$dir" in
    '') printf '%s' "$base" ;;
    /*) printf '%s' "$dir" ;;
    *) printf '%s/%s' "$base" "$dir" ;;
  esac
}

# hop_moves_head <target>: 0 when the segment parse_git_globals just read is a
# checkout or switch that moves HEAD. That is a branch-creating or detaching
# form of either one, `-` (the previous branch), or exactly one operand that
# resolves as a commit-ish and is neither HEAD nor the branch HEAD already
# points at. Path restores pass: anything carrying `--`, `-p`, or a pathspec
# file, and two or more operands (a tree-ish plus paths).
#
# Honest limits. The guard reads the command as text, never as the shell would
# expand it, so spellings that need the shell's own reading pass. They include:
# a `git checkout <name>` that git would DWIM into a new tracking branch from a
# remote, since it does not resolve as a commit-ish locally (the feature-branch
# cleanup's `git checkout main` always resolves), where `switch` takes the
# opposite answer and denies an operand that resolves nowhere; a `cd` into the
# main checkout earlier in the same command, since the target comes from `-C` or
# the payload's cwd, never from a `cd`; `--git-dir` or `--work-tree` aiming a
# command run elsewhere at the main checkout, for the same reason; a `-C` whose
# path carries an unexpanded variable or `~`, or is a relative `-C` stacked on an
# earlier one; a global option this parser does not know takes a separated value,
# whose own value then lands in the slot the subcommand is read from; and
# `gh pr checkout`, whose command word is not `git`.
hop_moves_head() {
  local target="$1" operand="" n=0 t skip_next=0 cur ref
  # The two subcommands spell their branch-creating flags differently, and the
  # difference is why they are read apart rather than together: `-c`/`-C` create
  # a branch for `switch` and mean something else entirely for `checkout`, where
  # `-C` is commit's reuse-message option. Past this point the operand analysis
  # is shared, so a switch naming the branch HEAD already holds reaches the same
  # no-op carve-out a checkout naming it does.
  case "$git_sub" in
    switch)
      for t in ${git_args[@]+"${git_args[@]}"}; do
        case "$t" in
          -c | -C | --create | --force-create | --orphan | --detach) return 0 ;;
        esac
      done
      ;;
    checkout)
      for t in ${git_args[@]+"${git_args[@]}"}; do
        case "$t" in -b | -B | --orphan | --detach) return 0 ;; esac
      done
      for t in ${git_args[@]+"${git_args[@]}"}; do
        case "$t" in -- | -p | --patch | --pathspec-from-file*) return 1 ;; esac
      done
      ;;
    *) return 1 ;;
  esac
  # Redirections are not operands: `git checkout main 2>/dev/null` names one.
  for t in ${git_args[@]+"${git_args[@]}"}; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$t" in
      *'>' | *'<') skip_next=1; continue ;;
      *[\<\>]*) continue ;;
      -*) [ "$t" = - ] || continue ;;
    esac
    [ "$n" -eq 0 ] && operand="$t"
    n=$((n + 1))
  done
  [ "$n" -eq 1 ] || return 1
  [ "$operand" = - ] && return 0
  case "$operand" in
    \"*\") operand="${operand#\"}"; operand="${operand%\"}" ;;
    \'*\') operand="${operand#\'}"; operand="${operand%\'}" ;;
  esac
  if ! git -C "$target" rev-parse --verify -q "${operand}^{commit}" >/dev/null 2>&1; then
    # An unresolvable operand is not a no-op for `switch`: git DWIMs a name
    # carried only by a remote into a new tracking branch and moves HEAD, and a
    # bare name resolves against refs/remotes/<name> rather than
    # refs/remotes/<remote>/<name>, so the test above cannot see one. Denying a
    # name that resolves nowhere at all refuses a command git would reject
    # anyway, which is the safe direction. `checkout` keeps the opposite answer,
    # the DWIM limit its honest-limits block above records
    # (gaia-react/gaia#2018).
    if [ "$git_sub" = switch ]; then return 0; fi
    return 1
  fi

  # A commit-ish operand still moves nothing when it names HEAD itself, or the
  # branch HEAD already points at, so neither is a hop. Denying them refused a
  # no-op, and the session most likely to hit it is the branch owner's own
  # after a restart, whose new session id no longer matches the breadcrumb.
  [ "$operand" = HEAD ] && return 1
  cur=$(git -C "$target" symbolic-ref -q HEAD 2>/dev/null) || cur=""
  ref=$(git -C "$target" rev-parse --symbolic-full-name "$operand" 2>/dev/null) || ref=""
  [ -n "$cur" ] && [ "$ref" = "$cur" ] && return 1
  return 0
}

# The guard's fail-open diagnostic. It takes the WHOLE message rather than a
# branch plus a cause: the arms below do not all fail at the same lookup, and
# one is reached before a branch name has been resolved at all, so a template
# naming one lookup misreports the others.
hop_unchecked() {
  printf 'block-main-destructive-git.sh: %s; allowing the command.\n' "$1" >&2
}

# hop_guard <target>: deny when all of these hold. The target is this
# repository's main checkout, not a linked worktree. Its HEAD is a branch other
# than main, master, or the default origin/HEAD names. That branch has an open
# pull request. And this session is not the one whose `gh pr create` opened it,
# per the breadcrumb .claude/hooks/capture-gh-artifact.sh writes; a missing
# breadcrumb counts as not the owner. The owner's post-merge cleanup passes
# because its pull request is no longer open by then, and subagents share their
# parent's session id, so they count as the owner too.
hop_guard() {
  local target="$1" branch default out rc sid bc errexit_was tmp
  if ! command -v gaia_is_linked_worktree >/dev/null 2>&1 \
     || ! command -v gaia_resolve_main_root >/dev/null 2>&1; then
    hop_unchecked "could not check whether $target is this repository's main checkout (main-root-lib.sh did not load)"
    return 0
  fi
  gaia_is_linked_worktree "$target" && return 0
  [ "$(gaia_resolve_main_root "$target" 2>/dev/null)" = "$main_root" ] || return 0

  branch=$(git -C "$target" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  case "$branch" in main | master) return 0 ;; esac
  default=$(git -C "$target" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) || default=""
  [ -n "$default" ] && [ "$branch" = "${default#origin/}" ] && return 0

  # The owner match is local and decides the verdict whatever the pull request's
  # state, so it runs before the network call rather than after it.
  errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  if [ -n "$_hook_root" ] && [ -f "$_hook_root/.gaia/scripts/gh-artifact-lib.sh" ]; then
    # shellcheck source=/dev/null
    . "$_hook_root/.gaia/scripts/gh-artifact-lib.sh" 2>/dev/null
  fi
  if [ "$errexit_was" = 1 ]; then set -e; fi
  if command -v gaia_gh_artifact_read >/dev/null 2>&1; then
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
    if [ -n "$sid" ]; then
      bc=$(gaia_gh_artifact_path "$(gaia_gh_artifact_cache_dir)" "$branch")
      # A year, not the lib's one-day default: session ids never repeat, so a
      # match proves ownership at any age, however long the file lives.
      [ -n "$(gaia_gh_artifact_read "$bc" "$sid" "$branch" 31536000)" ] && return 0
    fi
  fi

  if ! command -v gh >/dev/null 2>&1; then
    hop_unchecked "could not check whether '$branch' has an open pull request (gh is not on PATH)"
    return 0
  fi
  # `gh` has no request timeout of its own, and a blackholed network would hold
  # every checkout for an OS-length stall. Five seconds is several times a
  # normal `gh pr list` round-trip; past it the guard gives up and allows.
  #
  # The answer lands in a file rather than a command substitution's pipe. The
  # bound kills only the pid it backgrounded, so a `gh` on PATH that runs the
  # real binary WITHOUT `exec` leaves that grandchild alive still holding the
  # pipe, and a substitution waits for every process holding it: the bound
  # would not hold, and the diagnostic would claim one that had.
  tmp=$(mktemp -t gaia-hop-pr-XXXXXX 2>/dev/null) || tmp=""
  if [ -z "$tmp" ]; then
    hop_unchecked "could not check whether '$branch' has an open pull request (no temporary file could be created for the gh pr list output)"
    return 0
  fi
  (
    cd "$target" || exit 125
    gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' >"$tmp" 2>/dev/null &
    pid=$!
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$ticks" -ge 50 ]; then
        kill "$pid" 2>/dev/null || true
        exit 124
      fi
      sleep 0.1
      ticks=$((ticks + 1))
    done
    wait "$pid"
  ) && rc=0 || rc=$?
  out=$(cat "$tmp" 2>/dev/null) || out=""
  rm -f "$tmp"
  case "$rc" in
    0) ;;
    124) hop_unchecked "could not check whether '$branch' has an open pull request (gh pr list timed out after 5s)"; return 0 ;;
    125) hop_unchecked "could not check whether '$branch' has an open pull request ($target could not be entered to run gh pr list)"; return 0 ;;
    *) hop_unchecked "could not check whether '$branch' has an open pull request (the open pull-request lookup, gh pr list, exited $rc)"; return 0 ;;
  esac
  [ -n "$out" ] || return 0
  if ! [[ "$out" =~ ^[0-9]+$ ]]; then
    hop_unchecked "could not check whether '$branch' has an open pull request (gh pr list answered with something other than a pull-request number)"
    return 0
  fi
  # The open pull request is in hand by here, so the lookup that can still fail
  # is whose session opened it, not whether one is open.
  if ! command -v gaia_gh_artifact_read >/dev/null 2>&1; then
    hop_unchecked "could not check whether this session opened the open pull request on '$branch' (gh-artifact-lib.sh did not load)"
    return 0
  fi

  deny "The main checkout is holding branch '$branch', which has open pull request #$out: another session is working there, and moving this checkout's HEAD would pull the branch out from under it and forfeit its audit round. If you are cleaning up after a merge, take the worktree arm in wiki/concepts/PR Merge Workflow.md, which runs no git checkout. If this is your own branch, run the command yourself with the ! prefix."
}

# Walk each command-position segment. Separators (`| & ; ( )`, newlines) become
# line breaks so every line begins at a command word; leading env-var
# assignments are stripped to expose it. The commit/push rules act only on
# segments whose command word is `git`, so `git commit` / `git push` appearing
# as TEXT in another program's arguments never trips the gate.
# The directory a `cd` moves into governs every segment after it, so it is
# tracked as the walk goes rather than resolved once for the whole command. A
# command-wide value could not be replaced by a later `cd`, so a command that
# stepped into a worktree and back read the worktree's branch for a commit that
# landed on main.

# collapsed_substitutions <text>: print the command once more with every
# `$( … )` span replaced by a single placeholder word, and print nothing when
# the text carries none or the collapse changes nothing. Cutting at every `(`
# and `)` is what lets the walk read a command INSIDE a substitution, and is
# also what splits a substitution standing in git's OWN arguments away from the
# command word: `git -C "$(pwd)" commit` leaves no segment carrying both `git`
# and `commit`, so every rule armed on the subcommand went unarmed. This line
# is read IN ADDITION to the command's own, so the body still reaches the walk
# as its own segment and only the outer invocation is rejoined. The placeholder
# is a bare `_` so a subcommand or a refspec written inside the span cannot arm
# the rejoined segment with something it never spelled.
#
# Innermost first, so a nested span collapses over successive passes; the bound
# is a backstop. A span crossing a newline is left alone, since sed reads a
# line at a time: that leaves the segment cut where it already was, which is
# the direction that hides nothing the walk reads today.
# block-no-verify.sh carries the same function, and block-no-verify.bats pins
# the copies identical.
collapsed_substitutions() {
  local text="$1" prev pass=0
  # shellcheck disable=SC2016 # a literal opener matched in the text, not an expansion
  case "$text" in *'$('*) ;; *) return 0 ;; esac
  while [ "$pass" -lt 8 ]; do
    prev="$text"
    text=$(printf '%s' "$text" | sed -E 's/\$\([^()]*\)/_/g')
    [ "$text" = "$prev" ] && break
    pass=$((pass + 1))
  done
  [ "$text" = "$1" ] || printf '%s\n' "$text"
  return 0
}

lead_cd=""
# Set when a `cd` target did not resolve, which leaves the acting checkout
# genuinely unknown rather than merely untracked: the walk cannot tell a `cd`
# the shell FAILED to make (still in the previous checkout) from one it MADE
# into a checkout the scan could not expand (`cd -`, `cd "$SOMEWHERE"`), and
# those two land the command in different trees. A later `cd` that does
# resolve settles the question and clears it.
cd_ambiguous=0
cd_tracking=1
hop_checked=0
checked_hop_dir=""
if cmd_has_unquoted_group "$cmd"; then cd_tracking=0; fi

# The collapsed line is a second reading of the WHOLE command, its own `cd`
# segments included, so the walk enters it with no tracked directory standing
# and lets that reading re-derive one. Carrying the first reading's final `cd`
# across would put a `cd` that FOLLOWS a git segment in FRONT of that segment
# on the second reading, and a commit made before the command steps into
# another checkout would be read against the checkout it steps into.
#
# The boundary travels in band, on the same line stream the command text
# travels on, so its spelling is DERIVED per run rather than fixed. A fixed
# word would be one the guarded command can write for itself, and the arm below
# clears the tracked directory on any segment that matches: a command spelling
# it between two separators takes its own `cd` off the walk, and the commit
# after it is read against the checkout the command never lands in. That is a
# disarm rather than an over-block, which is the direction this guard must
# never fail in. The hook's pid and `$RANDOM` are both readable on bash 3.2 and
# neither is reachable from the command text.
#
# The spelling carries none of `| & ; ( )`, so the `tr` below leaves it
# standing on a line of its own, and it is not a command word any rule arms on.
walk_reset="__gaia_walk_reset_${$}_${RANDOM}__"
collapsed=$(collapsed_substitutions "$cmd")

while IFS= read -r seg; do
  if [ "$seg" = "$walk_reset" ]; then
    lead_cd=""
    cd_ambiguous=0
    continue
  fi

  # Command word = the first token past any leading whitespace, env-var
  # assignment prefix, shell reserved word, or redirection. What the shell
  # accepts in that run, each of which hid the whole invocation from a narrower
  # reading: `NAME+=value` is a command prefix exactly as `NAME=value` is
  # (`bash -c 'zz+=1 env'` prints `zz=1`); an assignment's value may be quoted
  # and carry whitespace (`GIT_AUTHOR_DATE="2024-01-01 12:00" git commit`), so
  # a value read as an unquoted run stops at the opening quote; a reserved
  # word or grouping token stands in command position with no `| & ; ( )` ahead
  # of the command word for the walk to cut at, with `time` taking an optional
  # `-p` or `--` of its own; and a redirection may lead a simple command
  # (`bash -c '>/tmp/x echo hi'` writes the file), so one standing ahead of the
  # invocation occupies the slot the command word is read from. bash 3.2 does
  # not populate BASH_REMATCH reliably, so strip with sed rather than a capture
  # loop.
  #
  # Honest limit: a command WRAPPER (`env`, `command`, `exec`, `nohup`,
  # `timeout`, `xargs`) also stands where the command word is read and is NOT
  # stripped, so it still hides the invocation. Each carries its own option
  # grammar, and a blind strip would misread `env -i git …` and `timeout 5 git
  # …`, so closing them needs a per-wrapper option table rather than this list.
  #
  # Second honest limit, of a different kind: a redirection whose target is
  # another descriptor (`2>&1`, `>&2`) never reaches this strip at all, because
  # the walk cuts segments at `&` and the invocation lands in a segment
  # beginning with the descriptor number. Closing it means not cutting at an
  # `&` that belongs to a redirection, which a separator split cannot tell from
  # `&&` without reading the command the way the shell does.
  #
  # block-no-verify.sh carries this expression too, and block-no-verify.bats
  # pins the copies identical: a widening applied to one and not the rest
  # leaves the gap open in whichever copy was missed.
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*\+?=([^[:space:]"'"'"']+|"[^"]*"|'"'"'[^'"'"']*'"'"')*|[0-9]*[<>][^[:space:]]*|[{!]|coproc|elif|else|while|until|then|time([[:space:]]+(-p|--))?|do|if)[[:space:]]+)*//')

  # A target the scan cannot READ leaves the previously tracked directory
  # STANDING and marks the checkout ambiguous; it does not clear the target,
  # and it does not trust it either. Both readings are live and the scan
  # cannot separate them: a `cd` the shell FAILED to make leaves the shell in
  # the directory the preceding one moved into, while `cd -` or
  # `cd "$SOMEWHERE"` is a `cd` that most likely SUCCEEDED somewhere the scan
  # cannot name, the main checkout included. Clearing disarms the first
  # reading, trusting the kept target disarms the second, so the kept target
  # answers the ordinary case and the ambiguity flag makes the rules below
  # test every checkout the command could be standing in.
  #
  # A target that reads as ANOTHER repository is not that case. The word
  # expanded, so nothing about where the shell is standing is unknown; it is
  # simply somewhere this repository's policy does not govern. Such a target
  # drops the tracked directory and leaves the segments after it reading this
  # hook's own, which is what they did before the ambiguity arm existed.
  if [ "$cd_tracking" -eq 1 ] && [[ "$seg_cmd" =~ ^cd([[:space:]]|$) ]]; then
    split_git_words "$seg_cmd"
    cd_kind=$(resolve_dir_kind "${w[1]:-}")
    case "$cd_kind" in
      'same '*)
        lead_cd="${cd_kind#same }"
        cd_ambiguous=0
        ;;
      'foreign '*)
        lead_cd=""
        cd_ambiguous=0
        ;;
      *)
        cd_ambiguous=1
        ;;
    esac
    continue
  fi

  [[ "$seg_cmd" =~ ^git([[:space:]]|$) ]] || continue

  parse_git_globals "$seg"

  # The hop check is the one arm here that can spend a bounded network lookup,
  # and the collapsed line re-emits the whole command, so a checkout whose
  # operand carries a `$( )` reaches this arm twice for one target: once
  # truncated at the paren, once rejoined. Answering a target only the first
  # time keeps that from doubling the hook's worst-case wait and from printing
  # the unchecked diagnostic twice for a single command. The memo keys on the
  # resolved target, so a command hopping in two different directories is still
  # checked in each.
  #
  # It spans `hop_guard` alone, and the split is what keeps the memo from
  # taking the guard off. `hop_guard`'s verdict is a function of the target,
  # the main checkout and the payload's session id, all invariant across the
  # segments of one command, so answering it once per target is sound.
  # `hop_moves_head` reads the operands `parse_git_globals` just set for THIS
  # segment, so it has to be asked per segment: a pathspec restore and a
  # checkout of the branch HEAD already holds both move nothing, and either one
  # memoised as the answer for its target would stand in for the branch switch
  # beside it in the same command.
  case "$git_sub" in
    checkout | switch)
      hop_dir=$(hop_target "$git_cwd")
      if hop_moves_head "$hop_dir"; then
        if [ "$hop_checked" -eq 0 ] || [ "$hop_dir" != "$checked_hop_dir" ]; then
          hop_checked=1
          checked_hop_dir="$hop_dir"
          hop_guard "$hop_dir"
        fi
      fi
      ;;
  esac
  [ "$foreign_repo" -eq 1 ] && continue

  # The checkout this segment acts on: its own `-C`, else the directory the most
  # recent preceding `cd` moved into, else this hook's working directory. A `cd`
  # into a linked worktree is this repository but another checkout, with its
  # own branch.
  #
  # The `-C` word goes through the same resolution the `cd` arm above uses
  # rather than reaching the branch read raw. The scan that produced it models
  # quoting but never expands, so a value carrying a variable or a
  # substitution is text naming no readable directory; read raw it makes the
  # branch read answer nothing, and every rule armed on the branch allows. An
  # UNREADABLE value therefore falls back to the tracked `cd`, else to this
  # hook's own directory, and marks the segment ambiguous so the rules below
  # test the other checkouts it could name too.
  #
  # A value naming a repository the scan CAN read does reach this line, in a
  # call that also carries a home command: the foreign stand-down above is a
  # whole-call verdict and answers home for such a call. That value names the
  # checkout outright, so it is read there, on the branch the command acts
  # on, exactly as it was before the ambiguity arm existed. Reading it as
  # ambiguous instead denied a sibling-repository commit against THIS
  # checkout's branch.
  #
  # Two populations pay for that, and the second is the larger one.
  #
  # A `-C` naming a real sibling checkout the scan could not expand is read
  # against the wrong tree and denied. That is a false deny rather than a
  # miss, and the escape is prompt-level bang mode, not a `!` written into the
  # command: this file's own command-word strip consumes a leading `!` as the
  # shell negation, so a command spelled that way is still read and still
  # denied.
  #
  # The larger one is command TEXT that merely quotes an unreadable directory
  # word. The segment walk splits on separators without modelling quoting, so
  # inside a quoted string either a segment beginning `cd <something-
  # unreadable>` with a `git commit` or `git push` word after it, or a segment
  # beginning `git -C <something-unreadable>` with one of those words in it,
  # reads as an invocation. Writing about a command of either shape is enough;
  # neither needs a `cd` and neither needs to run. That population is not new,
  # but the ambiguity arm makes it deny far more often: it consults the
  # main checkout, whose resting branch is normally `main`, where the reading
  # before it landed on the session's own checkout and a feature branch
  # allowed. Writing about these commands in a shell argument is therefore
  # denied where it used to pass, and the repair is a body FILE rather than an
  # inline argument, which is what the surrounding workflows prescribe anyway.
  # Narrowing this to a segment the walk knows is unquoted needs the shell's
  # own reading of the command, which is the same thing the honest limits on
  # `parse_git_globals` name.
  #
  # A `-C` that DOES resolve names the checkout outright, so it settles the
  # question whatever a preceding `cd` left behind.
  if [ -n "$git_cwd" ]; then
    cwd_kind=$(resolve_dir_kind "$git_cwd")
    case "$cwd_kind" in
      'same '*)
        branch_dir="${cwd_kind#same }"
        seg_ambiguous=0
        ;;
      'foreign '*)
        branch_dir="${cwd_kind#foreign }"
        seg_ambiguous=0
        ;;
      *)
        branch_dir="$lead_cd"
        seg_ambiguous=1
        ;;
    esac
  else
    branch_dir="$lead_cd"
    seg_ambiguous="$cd_ambiguous"
  fi

  # The words after the subcommand, where a push's own refspec lives. The
  # main/master tests below read these rather than the whole segment: arming the
  # rules on the parsed subcommand brings a global option's own VALUE within
  # reach of a pattern the old literal `git push` anchor kept it out of, and
  # `-c user.name=main` names no branch.
  push_args="${git_args[*]+${git_args[*]}}"

  # 1. Block commits while HEAD is on main or master.
  #
  # The two arms deny for different reasons and name different repairs, so
  # they are written separately: the first knows which checkout the commit
  # lands in, the second does not and denies because one it could reach is on
  # main. Answering the known case first keeps the ordinary deny's message
  # unchanged for the operator who is simply standing on main.
  if [ "$git_sub" = commit ]; then
    branch=$(current_branch "$branch_dir")
    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
      deny "Commits to '$branch' are forbidden (wiki/concepts/Git Workflow.md). Create a feature branch first."
    fi
    if [ "$seg_ambiguous" -eq 1 ]; then
      amb_branch=$(ambiguous_main_branch)
      if [ -n "$amb_branch" ]; then
        deny "This command names a directory this guard cannot read, so which checkout the commit lands in is unknown, and one it could reach is on '$amb_branch'. Commits to '$amb_branch' are forbidden (wiki/concepts/Git Workflow.md). Spell the directory literally so the guard can read it, or create a feature branch first. If this text only QUOTES a command rather than running one, the guard cannot tell the two apart: pass it through a file (--body-file, git commit -F) instead of an inline argument."
      fi
    fi
  fi

  # 2. Block force-push when target mentions main or master.
  if [ "$git_sub" = push ] \
     && [[ "$norm" =~ (--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]] \
     && [[ "$push_args" =~ (main|master)([[:space:]]|$|:) ]]; then
    deny "Force-push to main/master is forbidden (wiki/concepts/Git Workflow.md)."
  fi

  # 3. Block any `git push` originating from main/master (PR-only flow).
  #    Triggers when HEAD is on main/master OR when the push refspec explicitly
  #    names main/master/HEAD as the source. Closes the "forgot to switch
  #    branches" footgun.
  if [ "$git_sub" = push ]; then
    branch=$(current_branch "$branch_dir")
    on_main=0
    [[ "$branch" == "main" || "$branch" == "master" ]] && on_main=1

    # Refspec-targeted push from main/master/HEAD: e.g. `git push origin main`,
    # `git push origin HEAD:main`, `git push origin main:main`. Read from the
    # operands after the subcommand, so neither a global option ahead of `push`
    # nor one ahead of the remote can carry the refspec out of reach.
    refspec_main=0
    if push_refspec_names_main; then
      refspec_main=1
    fi

    # A directory word the guard could not read leaves the pushing checkout
    # unknown, so a candidate standing on main arms this rule the same way
    # reading main out of a known checkout does.
    #
    # Computed last, and only where the two arms above have not already
    # answered, because it is the only one that costs subprocesses: up to two
    # `symbolic-ref` reads whose answer the deny chain below would discard
    # whenever a cause it consults earlier holds.
    amb_main=0
    if [ "$seg_ambiguous" -eq 1 ] && [ "$on_main" -eq 0 ] && [ "$refspec_main" -eq 0 ]; then
      amb_branch=$(ambiguous_main_branch)
      if [ -n "$amb_branch" ]; then
        amb_main=1
      fi
    fi

    # Each condition denies with its own message because the repairs differ:
    # switching branches clears the first and does nothing for the refspec,
    # which needs the refspec itself respelled. Order is by how much of the
    # verdict the message can stand behind.
    #
    # On-main is answered first: an operator both standing on main and naming
    # it reads the branch repair, which settles the refspec too.
    #
    # The refspec is answered ahead of the ambiguity, because it holds whatever
    # checkout the push turns out to run from, and the ambiguity message's own
    # repairs do not hold for it. Told the checkout is unknown, an operator
    # already on a feature branch is offered a repair they have applied, and
    # spelling the directory literally only surfaces the refspec deny on the
    # next attempt. The ambiguity arm is last because it is the one that
    # reports an unanswered question rather than a settled cause.
    if [ "$on_main" -eq 1 ]; then
      deny "Plain 'git push' from main/master is forbidden (wiki/concepts/Git Workflow.md). Create a feature branch and open a PR."
    elif [ "$refspec_main" -eq 1 ]; then
      deny "This push's refspec names main, master or HEAD, which is forbidden from any branch (wiki/concepts/Git Workflow.md). Name the branch you are pushing explicitly and open a PR."
    elif [ "$amb_main" -eq 1 ]; then
      deny "This command names a directory this guard cannot read, so which checkout the push runs from is unknown, and one it could reach is on '$amb_branch'. Plain 'git push' from main/master is forbidden (wiki/concepts/Git Workflow.md). Spell the directory literally so the guard can read it, or create a feature branch and open a PR. If this text only QUOTES a command rather than running one, the guard cannot tell the two apart: pass it through a file (--body-file, git commit -F) instead of an inline argument."
    fi
  fi
done < <({
  printf '%s\n' "$cmd"
  if [ -n "$collapsed" ]; then printf '%s\n%s\n' "$walk_reset" "$collapsed"; fi
} | tr '|&;()' '\n')

exit 0
