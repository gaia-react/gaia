---
type: meta
title: Hot Cache
status: active
created: 2026-06-12
updated: 2026-06-12
tags: [meta, cache]
---

# Recent Context

## Last Updated

2026-06-12. Released as GAIA v1.6.1. Fresh slate.

## Active Threads

- claude-obsidian PostCompact hot-cache restore is now handled by GAIA's own hooks (`wiki-recompact-{sentinel,inject}.sh`, registered in `.claude/settings.json`), so it no longer depends on the plugin's prompt hook. Optional cleanup: `jq 'del(.hooks.PostCompact)'` on the plugin cache silences a cosmetic "prompt-type hooks not supported" error if one ever shows up.
