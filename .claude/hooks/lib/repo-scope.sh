#!/usr/bin/env bash
# Shared helper: decide whether a Bash command acts on a DIFFERENT git repo
# than the one these hooks are installed in (the "home repo").
#
# Template-distributed and portable: the home repo is whatever repo contains
# .claude/hooks (resolved via `git rev-parse --show-toplevel`) — never a
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
# single capture) returns 1 so the caller still enforces — protection never
# weakens silently, even for crafted command strings.

cmd_targets_foreign_repo() {
  local cmd="$1"
  local home_top target_dir top ghrepo

  home_top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$home_top" ] || return 1

  # 1. Explicit `gh ... -R owner/repo` / `--repo owner/repo` (space OR `=`
  #    form). gh ignores cwd when this is given, so it is authoritative.
  #    Comparison is repo-NAME only (basename): a same-named fork
  #    (`-R myfork/<homename>`) classifies as home and over-enforces —
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

  # Expand a leading ~ (our cross-repo flows use ~/path targets). The tilde
  # arrives as a literal character in the command text — bash never expanded
  # it because it was inside the tool_input string — so strip it by offset.
  # SC2088 fires on the quoted tilde, but these are case PATTERNS matching a
  # literal '~' in the input string, not an expansion attempt — intentional.
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
