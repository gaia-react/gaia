---
type: meta
status: active
created: 2026-04-20
updated: 2026-05-06
tags: [meta, schema]
---

# GAIA React: LLM Wiki

Mode: B (Codebase) + E (Research)
Plugin baseline: claude-obsidian v1.6.0 (DragonScale features intentionally not adopted — see [[DragonScale Opt-Out]])
Purpose: Persistent knowledge base for the GAIA React workflow — architecture, conventions, decisions, Claude integration.
Owner: Steven Sacks
Created: 2026-04-20

## Structure

```
wiki/
├── index.md            # master catalog
├── log.md              # chronological ingest log (newest at TOP)
├── hot.md              # ~200-word recent context cache (Stop-hook enforced)
├── overview.md         # executive summary
├── modules/            # major architectural areas (routing, auth, i18n, etc.)
├── components/         # reusable UI components (Form, Toast, Layout, etc.)
├── decisions/          # ADRs — why GAIA chose X over Y
├── dependencies/       # external deps with role + version
├── flows/              # data flows (auth, theme, language, form submit)
├── entities/           # GAIA project, contributors, ecosystem actors
├── concepts/           # ideas/patterns (Quality Gate, Co-location, Thin Routes)
└── meta/               # dashboards, lint reports
```

## Conventions

- All notes use YAML frontmatter: type, status, created, updated, tags (minimum)
- Wikilinks use `[[overview]]` — filenames are unique, no paths needed
- `.raw/` contains source documents — never modify them
- `wiki/index.md` is the master catalog — update on every ingest
- `wiki/log.md` is append-only — new entries at the TOP
- Keep pages 100-300 lines; split if longer

## Operations

- Ingest: drop a source in `.raw/`, say "ingest [filename]"
- Query: ask any question — Claude reads `hot.md` → `index.md` → drills in
- Lint: say "lint the wiki" for a health check
- Save: "/save" to file the current chat as a note
