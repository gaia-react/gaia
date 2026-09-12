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
# That is why this hook sits on the excluded side of the degrade table in
# .gaia/tests/hooks/audit-hook-lib-degrade.bats: it reaches no reporting path on
# a degraded run, because a missing carve-out is a silent fail-open here rather
# than a deny, and its entry there names this warrant.
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
parse_git_globals() {
  local -a w kept
  local i=0 n t globals=0
  git_cwd="" git_sub=""
  git_args=()
  read -ra w <<<"$1"
  n=${#w[@]}
  while [ "$i" -lt "$n" ]; do
    t="${w[$i]}"
    if [ "$globals" -eq 1 ]; then
      case "$t" in
        -C) git_cwd="${w[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
        -c | --git-dir | --work-tree | --namespace)
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
# checkout or switch that moves HEAD. Every `git switch` does, and so does
# `git checkout` with `-b`/`-B`/`--orphan`/`--detach`, with `-` (the previous
# branch), or with exactly one operand that resolves as a commit-ish. Path
# restores pass: anything carrying `--`, `-p`, or a pathspec file, and two or
# more operands (a tree-ish plus paths).
#
# Honest limits. The guard reads words split on whitespace, never the command as
# the shell would expand it, so spellings that need the shell's own reading pass.
# They include: a `git checkout <name>` that git would DWIM into a new tracking
# branch from a remote, since it does not resolve as a commit-ish locally (the
# feature-branch cleanup's `git checkout main` always resolves); a `cd` into the
# main checkout earlier in the same command, since the target comes from `-C` or
# the payload's cwd, never from a `cd`; `--git-dir` or `--work-tree` aiming a
# command run elsewhere at the main checkout, for the same reason; a `-C` whose
# path is quoted with a space in it, carries an unexpanded variable or `~`, or is
# a relative `-C` stacked on an earlier one; a global option whose value this
# parser does not know to skip, such as `--config-env`; and `gh pr checkout`,
# whose command word is not `git`.
hop_moves_head() {
  local target="$1" operand="" n=0 t skip_next=0 cur ref
  case "$git_sub" in
    switch) return 0 ;;
    checkout) ;;
    *) return 1 ;;
  esac
  for t in ${git_args[@]+"${git_args[@]}"}; do
    case "$t" in -b | -B | --orphan | --detach) return 0 ;; esac
  done
  for t in ${git_args[@]+"${git_args[@]}"}; do
    case "$t" in -- | -p | --patch | --pathspec-from-file*) return 1 ;; esac
  done
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
  git -C "$target" rev-parse --verify -q "${operand}^{commit}" >/dev/null 2>&1 || return 1

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
# naming one lookup misreports the others
# (.claude/rules/partial-cause-reporting.md).
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
      # match proves ownership at any age, and the janitor's retention already
      # bounds how long the file lives.
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
while IFS= read -r seg; do
  # Command word = the first token after any leading whitespace + env-var
  # assignments (`WORD=value `). bash 3.2 does not populate BASH_REMATCH
  # reliably, so strip with sed rather than a capture loop.
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  [[ "$seg_cmd" =~ ^git([[:space:]]|$) ]] || continue

  parse_git_globals "$seg"

  case "$git_sub" in
    checkout | switch)
      hop_dir=$(hop_target "$git_cwd")
      if hop_moves_head "$hop_dir"; then hop_guard "$hop_dir"; fi
      ;;
  esac
  [ "$foreign_repo" -eq 1 ] && continue

  # The checkout this segment acts on: its own `-C`, else the leading `cd` the
  # repo-scope verdict resolved, else this hook's working directory. A `cd`
  # into a linked worktree is this repository but another checkout, with its
  # own branch.
  #
  # Honest limit: the leading `cd` target stands for every segment, and a later
  # `cd` does not replace it. From a main checkout on main,
  # `cd <worktree> && git status && cd <main> && git commit` therefore reads
  # the worktree's branch and allows a commit that lands on main
  # (gaia-react/gaia#2014).
  branch_dir="${git_cwd:-${GAIA_REPO_SCOPE_LEAD_CD:-}}"

  # 1. Block commits while HEAD is on main or master.
  if [ "$git_sub" = commit ]; then
    branch=$(current_branch "$branch_dir")
    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
      deny "Commits to '$branch' are forbidden (wiki/concepts/Git Workflow.md). Create a feature branch first."
    fi
  fi

  # 2. Block force-push when target mentions main or master.
  if [ "$git_sub" = push ] \
     && [[ "$norm" =~ (--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]] \
     && [[ "$norm" =~ (main|master)([[:space:]]|$|:) ]]; then
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
    # `git push origin HEAD:main`, `git push origin main:main`. Matched against
    # the words AFTER the subcommand, so a global option ahead of `push` cannot
    # carry the refspec out of the pattern's reach the way anchoring the
    # pattern on a literal `git push` did.
    refspec_main=0
    push_args="${git_args[*]+${git_args[*]}}"
    if [[ "$push_args" =~ ^[^[:space:]]+[[:space:]]+(HEAD|main|master)([[:space:]]|:|$) ]]; then
      refspec_main=1
    fi

    if [[ "$on_main" -eq 1 || "$refspec_main" -eq 1 ]]; then
      deny "Plain 'git push' from main/master is forbidden (wiki/concepts/Git Workflow.md). Create a feature branch and open a PR."
    fi
  fi
done < <(printf '%s\n' "$cmd" | tr '|&;()' '\n')

exit 0
