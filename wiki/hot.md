---
type: meta
title: Hot Cache
status: active
created: 2026-06-12
updated: 2026-10-03
tags: [meta, cache]
---

# Recent Context

## Last Updated

2026-10-03. External tool integrations upgraded: claude-obsidian 2.2.0, Serena v1.7.0, playwright-cli 0.1.22, react-doctor 0.9.14.

## Key Recent Facts

- GAIA owns the `wiki/hot.md` load: `wiki-hot-inject.sh` prints it on every SessionStart source, capped at 4096 bytes with a truncation notice. The plugin's own load stays off.
- The Stop hook prompts a `hot.md` refresh on committed wiki changes and on uncommitted `wiki/` edits made this session (fingerprint baselined at session start).
- Serena reads `language_servers:` (pre-1.7 name `languages:`); collaborators re-register before anyone commits a migrated `.serena/project.yml`.
- The playwright-cli skill is vendored verbatim with a sha256 marker under `.gaia/vendor/`.

## Recent Changes

- Plugin id is `claude-obsidian@agricidaniel-claude-obsidian`; Python 3.11+ required.
- `/update-deps` reports a playwright-cli global-tool row.

## Active Threads

- Maintainer machine upgrade steps follow the merge (plugin reinstall, Serena re-registration, global playwright-cli).
