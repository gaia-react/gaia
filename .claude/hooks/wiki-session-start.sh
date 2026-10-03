#!/bin/bash
# GAIA-owned wiki hook. Upstream contract: claude-obsidian/hooks/hooks.json::SessionStart
# Why GAIA overrides: claude-obsidian 2.x no longer commits wiki edits itself, so
# the Stop hook needs two baselines from the session's start: the HEAD it
# diffs commits against, and a fingerprint of the wiki/ edits already
# uncommitted, so it reports only what this session changed. Delivering
# wiki/hot.md into context is wiki-hot-inject.sh's job, not this hook's.

git_directory=$(git rev-parse --git-dir 2>/dev/null) || exit 0
git rev-parse HEAD > "$git_directory/claude-session-start" 2>/dev/null || true

_hook_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0

# Fail-open: without the library the dirty baseline is skipped and the Stop
# hook seeds one itself on its first run.
if [ -f "$_hook_directory/lib/wiki-dirty-fingerprint.sh" ]; then
  . "$_hook_directory/lib/wiki-dirty-fingerprint.sh"
  _repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || _repository_root=""
  if [ -n "$_repository_root" ] && [ -d "$_repository_root/wiki" ]; then
    printf '%s' "$(gaia_wiki_dirty_fingerprint "$_repository_root")" \
      > "$git_directory/claude-session-wiki-dirty" 2>/dev/null || true
  fi
fi

# Runs the wiki-landing catch-up (a merged wiki-sync branch's local reap and
# base fast-forward). Side-effect only; never blocks the session.
[ -f "$_hook_directory/local-janitor.sh" ] && bash "$_hook_directory/local-janitor.sh" || true

exit 0
