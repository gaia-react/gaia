#!/usr/bin/env bash
# GAIA-owned wiki hook. Pairs with wiki-recompact-sentinel.sh (PostCompact).
#
# On the first UserPromptSubmit after a context compaction, re-inject
# wiki/hot.md into context (a UserPromptSubmit hook's stdout is added to the
# model's context, the same mechanism wiki-drift-check.sh relies on) and clear
# the sentinel so it fires exactly once per compaction.
#
# Why: compaction drops hook-injected context, including the SessionStart hot
# cache. This restores it deterministically, replacing the upstream prompt-type
# PostCompact hook that some Claude Code builds reject. A no-op on every prompt
# where no compaction has occurred (sentinel absent).

set -euo pipefail

# Best-effort: any internal failure exits 0. Never block prompt submission.
trap 'exit 0' ERR

sentinel=".claude/wiki-recompact-pending"
[ -f "$sentinel" ] || exit 0

# Consume the sentinel first: a single failed injection must not loop forever.
rm -f "$sentinel"

[ -f wiki/hot.md ] || exit 0

printf '# Restored wiki hot cache after context compaction:\n\n'
cat wiki/hot.md

exit 0
