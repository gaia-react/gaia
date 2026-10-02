#!/usr/bin/env bash
# UserPromptSubmit hook: deliver the janitor's one-line base-catch-up report.
#
# local-janitor.sh writes at most one line to
# .gaia/local/cache/shared/wiki-base-catchup.report when its own fast-forward of
# the base branch is refused. A UserPromptSubmit hook's stdout is injected into
# the conversation, which a SessionStart hook's exit-0 stderr is not, so this
# hook is the delivery channel. Read-and-delete: the line surfaces exactly once.

set -euo pipefail

# Best-effort: any internal failure exits 0. Never block prompt submission.
trap 'exit 0' ERR

# Two roots, because one cannot answer both questions:
#
#   _hook_root  WHERE this checkout's own libraries are, from this file's
#               on-disk location rather than the process working directory.
#   main_root   WHICH TREE the report belongs to. The janitor writes it under
#               gaia_resolve_main_root, so the reader names that same root. From
#               any subdirectory, and from a linked worktree whose .gaia/local
#               is not provisioned, a working-directory-relative path names a
#               different tree than the writer.
#
# The ERR trap is disarmed across the load, not merely `set +e`: the two are
# independent, and the armed trap fires on a failing command whatever errexit
# says. An unparseable library (an unresolved merge conflict, a truncated
# write) would otherwise exit 0 from inside the source, before the drain runs.
# The fallback chain ends at `pwd`, so a checkout where neither the resolver nor
# git answers still drains the path a bare relative literal would name.
_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _hook_root=''
_main_root_library="$_hook_root/.gaia/scripts/main-root-lib.sh"
trap - ERR
set +e
# shellcheck source=/dev/null
[ -n "$_hook_root" ] && [ -f "$_main_root_library" ] && . "$_main_root_library" 2>/dev/null
set -e
trap 'exit 0' ERR
main_root=''
if type gaia_resolve_main_root >/dev/null 2>&1; then
  main_root="$(gaia_resolve_main_root 2>/dev/null)" || main_root=''
fi
[ -n "$main_root" ] || main_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

catchup_report="$main_root/.gaia/local/cache/shared/wiki-base-catchup.report"
if [ -f "$catchup_report" ]; then
  head -n 1 "$catchup_report" 2>/dev/null || true
  rm -f "$catchup_report" 2>/dev/null || true
fi

exit 0
