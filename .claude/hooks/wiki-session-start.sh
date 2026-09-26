#!/bin/bash
# GAIA-owned wiki hook. Upstream contract: claude-obsidian/hooks/hooks.json::SessionStart
# Why GAIA overrides: upstream cats wiki/hot.md and prompts a silent re-read; we
# instead record HEAD so the Stop hook can detect wiki commits (the plugin's own
# Stop diff misses changes already auto-committed by its PostToolUse hook).
# Hot-cache restoration is left to the model + claude-obsidian:wiki skill.

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
git rev-parse HEAD > "$GIT_DIR/claude-session-start" 2>/dev/null || true

_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0

# Runs the wiki-landing catch-up (a merged wiki-sync branch's local reap and
# base fast-forward). Side-effect only; never blocks the session.
[ -f "$_hook_dir/local-janitor.sh" ] && bash "$_hook_dir/local-janitor.sh" || true

exit 0
