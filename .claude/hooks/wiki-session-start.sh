#!/bin/bash
# GAIA-owned wiki hook. Upstream contract: claude-obsidian/hooks/hooks.json::SessionStart
# Why GAIA overrides: upstream cats wiki/hot.md and prompts a silent re-read; we
# instead record HEAD so the Stop hook can detect wiki commits (the plugin's own
# Stop diff misses changes already auto-committed by its PostToolUse hook).
# Hot-cache restoration is left to the model + claude-obsidian:wiki skill.

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
git rev-parse HEAD > "$GIT_DIR/claude-session-start" 2>/dev/null || true

# Clear stale per-session caches so state from a prior session doesn't carry over.
rm -f .gaia/local/cache/shared/coaching-active.txt 2>/dev/null

# Idempotent best-effort re-assertion of per-machine memory contracts.
# Always exits 0; guarded with `|| true` for defense in depth.
if [ -x .gaia/cli/gaia ]; then
  .gaia/cli/gaia mentorship _internal-assert-memory-rules >/dev/null 2>&1 || true
fi

# Bounded GC of .gaia/local working-state residue (orphaned audit markers,
# completed-but-unswept plan dirs, stray empty dirs). Side-effect only; never
# blocks the session. See local-janitor.sh for the provable-death contract.
[ -f .claude/hooks/local-janitor.sh ] && bash .claude/hooks/local-janitor.sh || true

exit 0
