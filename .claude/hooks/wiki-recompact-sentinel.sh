#!/usr/bin/env bash
# GAIA-owned wiki hook. Upstream contract: claude-obsidian/hooks/hooks.json::PostCompact
# (a prompt-type hook asking the model to silently re-read wiki/hot.md).
#
# Why GAIA overrides: prompt-type hooks are rejected on some Claude Code builds,
# and even where valid they depend on the model choosing to act. This
# command-type hook drops a sentinel instead; wiki-recompact-inject.sh
# (UserPromptSubmit) re-injects hot.md deterministically on the next turn.
#
# Hook-injected context does not survive compaction, so the hot cache must be
# restored afterward. PostCompact command hooks cannot inject their stdout into
# context, hence the sentinel handoff to UserPromptSubmit. Pairs with
# wiki-recompact-inject.sh; neither does anything without the other.

set -euo pipefail

# Best-effort: any internal failure exits 0. Never disrupt the compaction event.
trap 'exit 0' ERR

# Nothing to restore if there is no hot cache.
[ -f wiki/hot.md ] || exit 0

mkdir -p .claude
: > .claude/wiki-recompact-pending

exit 0
