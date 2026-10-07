---
type: meta
status: active
created: 2026-04-20
updated: 2026-10-03
tags: [meta, schema]
---

# GAIA React: LLM Wiki

Mode: B (Codebase) + E (Research)
Plugin baseline: `.claude/commands/setup-gaia.md` owns it (DragonScale features intentionally not adopted, see [[DragonScale Opt-Out]])
Purpose: Persistent knowledge base for the GAIA React workflow: architecture, conventions, decisions, Claude integration.
<!-- gaia:maintainer-only:start -->
Owner: Steven Sacks
<!-- gaia:maintainer-only:end -->
Created: 2026-04-20

## Structure

```
wiki/
├── index.md            # master catalog (/gaia-wiki maintains it)
├── log.md              # change ledger (gaia wiki log-prepend writes it, newest at TOP)
├── hot.md              # ~200-word recent context cache (wiki-hot-inject.sh loads it, the Stop hook prompts the refresh)
├── overview.md         # executive summary
├── modules/            # major architectural areas (routing, auth, i18n, etc.)
├── components/         # reusable UI components (Form, Toast, Layout, etc.)
├── decisions/          # ADRs: why GAIA chose X over Y
├── dependencies/       # external deps with role + version
├── flows/              # data flows (auth, theme, language, form submit)
<!-- gaia:maintainer-only:start -->
├── entities/           # GAIA project, contributors, ecosystem actors
<!-- gaia:maintainer-only:end -->
├── concepts/           # ideas/patterns (Quality Gate, Co-location, Thin Routes)
<!-- gaia:maintainer-only:start -->
└── meta/               # dashboards, lint reports
<!-- gaia:maintainer-only:end -->
```

## Conventions

- All notes use YAML frontmatter: type, status, created, updated, tags (minimum)
- Wikilinks use `[[overview]]` - filenames are unique, no paths needed
- `wiki/index.md` is the master catalog - `/gaia-wiki` maintains it
- `wiki/log.md` is append-only - new entries at the TOP
- Keep pages 100-300 lines; split if longer

## Operations

- Query: ask any question - Claude reads `hot.md` → `index.md` → drills in
- Maintenance: `/gaia-wiki` runs sync, consolidate, and lint with fixes, and opens one PR when run from `main`
