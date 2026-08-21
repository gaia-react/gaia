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
# blocking consumer keeps enforcing; over-enforcement is safe. Reading a
# foreign command as home is not safe for a consumer that acts: it writes to a
# pull request or an issue the command never named. So this one resolves every
# ambiguity to 0 ("foreign") and the caller declines to act.
#
# Comparison. gh identifies a repository as [HOST/]OWNER/REPO, so this compares
# the WHOLE value against one `gh repo view --json nameWithOwner,url` call,
# case-insensitively because GitHub resolves OWNER/REPO that way. The guard
# above compares the repo-NAME half against the checkout's directory basename,
# which reads a same-named fork (`--repo other-org/<homename>` from a checkout
# named `<homename>`, the ordinary fork topology) as home. That is the safe
# direction there and the wrong one here.
#
# Only the `-R`/`--repo` arm is replaced. A command with no explicit target is
# handed to the guard above unchanged, so its `git -C` and `cd` arms are shared
# verbatim rather than reimplemented.
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

# Whole-command form, for a consumer with no scanner of its own. It captures
# the target with the same regex arm 1 uses and hands it to the comparison
# above.
cmd_targets_foreign_repo_slug() {
  local cmd="$1"
  local ghrepo

  # Same capture as arm 1 above. It keeps any surrounding quote characters, so
  # a quoted value (`--repo="owner/repo"`) matches nothing below and reads as
  # foreign: the caller declines to act on a value it did not parse, which is
  # this entry point's safe direction.
  ghrepo=$(printf '%s' "$cmd" | sed -nE 's/.*(-R|--repo)[[:space:]=]+([^[:space:]]+).*/\2/p' | head -1)

  # gh also accepts `-R` attached to its value (`-Rowner/repo`), which the
  # capture above misses because it requires a separator. A blocking consumer
  # that misses it falls through to "home" and over-enforces, which is safe
  # there, so arm 1 is left exactly as those consumers depend on it. An acting
  # consumer that misses it acts on a repository the command explicitly named
  # as another one, so this entry point reads the attached spelling too.
  # `--repo` cannot attach (gh requires `=` or a space for a long flag) and
  # cannot match here either, since the character before `-R` would be `-`.
  [ -n "$ghrepo" ] || ghrepo=$(printf '%s' "$cmd" | sed -nE 's/.*(^|[[:space:]])-R([^[:space:]]+).*/\2/p' | head -1)

  if [ -z "$ghrepo" ]; then
    # No explicit target: gh resolves from cwd, which is exactly what the
    # guard above's remaining arms answer.
    if cmd_targets_foreign_repo "$cmd"; then return 0; fi
    return 1
  fi

  if repo_slug_is_foreign "$ghrepo"; then return 0; fi
  return 1
}
