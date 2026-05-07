#!/bin/bash
# GAIA-owned wiki hook. Upstream contract: claude-obsidian/hooks/hooks.json::SessionStart
# Why GAIA overrides: upstream cats wiki/hot.md and prompts a silent re-read; we
# instead record HEAD so the Stop hook can detect wiki commits (the plugin's own
# Stop diff misses changes already auto-committed by its PostToolUse hook).
# Hot-cache restoration is left to the model + claude-obsidian:wiki skill.

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
git rev-parse HEAD > "$GIT_DIR/claude-session-start" 2>/dev/null || true

# Clear telemetry coaching-active cache at session start (SPEC-001 UAT-038).
# Phase 5 task-adaptation-inject writes `1` on each non-empty injection;
# clearing here ensures stale state from a prior session doesn't carry over.
rm -f .gaia/cache/coaching-active.txt 2>/dev/null

# Re-assert the mentorship-display rule's projection into per-machine memory.
# When mentorship is enabled, this rewrites
# ~/.claude/projects/<slug>/memory/feedback_mentorship_display.md from the
# bundled CLI text and ensures MEMORY.md indexes it. When disabled, it
# removes both. Idempotent and best-effort — never blocks session start.
# The CLI subcommand always exits 0; we still guard with `|| true` for
# defense in depth.
if [ -x .gaia/cli/gaia ]; then
  .gaia/cli/gaia mentorship _internal-assert-display-rule >/dev/null 2>&1 || true
fi

exit 0
