#!/bin/bash
# GAIA-owned SessionStart hook (startup and resume). Runs the wiki-landing
# janitor, then prints the one-line report the janitor leaves when its
# fast-forward of the base branch is refused. A SessionStart hook's plain
# stdout reaches Claude's context, so the print is the delivery. The report is
# read, then deleted, so it surfaces exactly once.
#
# Fail-open: no ERR trap and no `set -e`, so a library that fails to parse
# costs the main-root lookup, never the print.

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

_hook_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0

# Runs the wiki-landing catch-up (a merged wiki-sync branch's local reap and
# base fast-forward). Never blocks the session.
[ -f "$_hook_directory/local-janitor.sh" ] && bash "$_hook_directory/local-janitor.sh" || true

# The janitor writes the report under the main root, so the reader names that
# same root: a working-directory-relative path names a different tree from a
# subdirectory or an unprovisioned linked worktree. The library is read from
# this hook's own tree. The fallback chain ends at `pwd`, so a checkout where
# neither the resolver nor git answers still reads the path a bare relative
# literal would name.
_main_root_library="$_hook_directory/../../.gaia/scripts/main-root-lib.sh"
# shellcheck source=/dev/null
[ -f "$_main_root_library" ] && . "$_main_root_library" 2>/dev/null
main_root=''
if type gaia_resolve_main_root >/dev/null 2>&1; then
  main_root="$(gaia_resolve_main_root 2>/dev/null)" || main_root=''
fi
[ -n "$main_root" ] || main_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

catchup_report="$main_root/.gaia/local/cache/shared/wiki-base-catchup.report"
if [ -f "$catchup_report" ]; then
  head -n 1 "$catchup_report" 2>/dev/null
  rm -f "$catchup_report" 2>/dev/null
fi

exit 0
