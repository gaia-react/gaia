---
type: meta
title: 'Lint Report 2026-04-27'
created: 2026-04-27
updated: 2026-04-27
tags: [meta, lint]
status: active
---

# Wiki Lint Report: 2026-04-27

Run after two commits: `fddcbd2` (`feat: migrate @mswjs/data → @msw/data, overhaul ESLint plugins`) and `db82d39` (`docs: update wiki and rules for newly-active ESLint plugins`). Previous report: [[lint-report-2026-04-26]].

## Summary

- Pages scanned: 85
- Issues found: 9 (2 critical, 4 warnings, 3 suggestions)
- Auto-fixed: 0
- DragonScale: not adopted: checks 7 and 8 skipped

---

## Critical (must fix)

### C1. Six wiki pages have stale `updated:` frontmatter after 2026-04-27 edits

- **Affected**: `wiki/modules/MSW Handlers.md`, `wiki/modules/Storybook Stories.md`, `wiki/modules/Testing.md`, `wiki/overview.md`, `wiki/dependencies/MSW.md`, `wiki/dependencies/Storybook.md`
- **Problem**: Commits `fddcbd2` and `db82d39` on 2026-04-27 modified all six files (content updates for `@msw/data` migration and new ESLint plugin docs). All six still carry `updated: 2026-04-20` in frontmatter: unchanged since the initial ingest. The only exception is `wiki/concepts/ESLint Fixes.md`, which was correctly bumped to `updated: 2026-04-27`.
- **Suggested fix**: Set `updated: 2026-04-27` in the frontmatter of all six files.

### C2. `wiki/overview.md` architecture tree and Tech Stack table contain stale claims

- **Affected**: `wiki/overview.md` lines 29 and 45 (carried forward from prior report C4 and W4: still unresolved)
- **Problem**:
  1. Line 29: `**State**: Plain React Context+Provider (Theme)`. After the Dark Mode Modernization (2026-04-26), the `<State>` barrel is a no-op passthrough. `ThemeProvider` was deleted. The `(Theme)` parenthetical is factually wrong.
  2. Line 45: `pages/ | page-specific UI (Auth, Public, Session)`. Both `app/pages/Auth/` and `app/pages/Session/` were deleted in Phase D. Only `app/pages/Public/` remains on disk.
- **Suggested fix**:
  1. Change line 29 to `**State**: Plain React Context+Provider (no built-in slices: add your own)` or remove the `(Theme)` parenthetical.
  2. Change line 45 to `pages/            page-specific UI (Public/: add Session/ when you add auth)`.

---

## Warnings (should fix)

### W1. `wiki/hot.md` branch claim is stale

- **Affected**: `wiki/hot.md` line 25
- **Problem**: States `Branch feat/dark-mode-update`. The current git branch is `feat/update-msw-data-and-eslint`. The hot cache is meant to reflect current work; it is pointing at the wrong branch and last-shipped context.
- **Suggested fix**: Rewrite `wiki/hot.md` to reflect the current branch (`feat/update-msw-data-and-eslint`), the `@msw/data` migration and ESLint plugin overhaul as last-shipped work, and the active PR if one exists.

### W2. `wiki/index.md` missing entry for `wiki/meta/lint-report-2026-04-27.md`

- **Affected**: `wiki/index.md`: `## Meta` section
- **Problem**: `lint-report-2026-04-27` (this file) has no entry in `index.md`. Convention is that every new page is added to the index. Currently the Meta section lists `lint-report-2026-04-26` and `lint-report-2026-04-21`.
- **Suggested fix**: Add `- [[lint-report-2026-04-27]]` to the `## Meta` section of `wiki/index.md`.

### W3. `wiki/README.md` not in `wiki/index.md` (carried forward: third consecutive report)

- **Affected**: `wiki/README.md`
- **Problem**: The vault schema document is not listed in `index.md`. Its only inbound links are in `log.md` historical text. This was flagged as W1 in the 2026-04-21 report, W3 in the 2026-04-26 report, and remains unfixed. One inbound from `log.md` keeps it off the orphan list, but it is effectively undiscoverable.
- **Suggested fix**: Add `- [[README]]: vault schema, mode declaration, conventions` to the `## Meta` section of `wiki/index.md`.

### W4. `wiki/log.md` missing entry for the `@msw/data` migration and ESLint overhaul

- **Affected**: `wiki/log.md`: top (most-recent entry position)
- **Problem**: Commits `fddcbd2` and `db82d39` on 2026-04-27 represent a significant dependency migration (`@mswjs/data` → `@msw/data` v1, API rewrite) plus seven ESLint plugin changes. The log's most recent entry covers the dark mode rewrite (2026-04-26). Per wiki convention, significant feature commits that touch wiki pages get a log entry.
- **Suggested fix**: Add a `[2026-04-27] feat | @msw/data migration + ESLint plugin overhaul` entry at the top summarising: `@mswjs/data@0.16.2` → `@msw/data@1.1.5` (Collection-based API, async `resetTestData()`), newly-wired plugins (`testing-library`, `jest-dom`, `you-dont-need-lodash-underscore`), replaced/removed plugins, wiki pages updated, and the key insight that `resetTestData()` is now async and must be `await`ed.

---

## Suggestions (worth considering)

### S1. `@msw/data` mentioned in seven pages but has no wiki page

- **Affected**: `wiki/overview.md`, `wiki/dependencies/MSW.md`, `wiki/modules/MSW Handlers.md`, `wiki/modules/Storybook Stories.md`, `wiki/modules/Testing.md`, `wiki/concepts/API Service Pattern.md`, `wiki/dependencies/Storybook.md`
- **Problem**: `@msw/data` is now a first-class part of GAIA's test infrastructure. It appears in seven pages, always as a bare package name with no dedicated wiki page. The `@mswjs/data` predecessor had the same treatment: but the v1 migration introduced a meaningfully different API (Standard Schema, `Collection` class, async mutations). The `[[MSW Handlers]]` page covers usage well, but there is no dedicated dependency page for `@msw/data` as there is for `[[MSW]]`.
- **Suggested fix** (optional): Create `wiki/dependencies/@msw-data.md` (type: dependency) covering package name, version, role, `Collection` API shape, and link to `[[MSW Handlers]]`. Low priority given the thorough coverage in `[[MSW Handlers]]` already.

### S2. `[[Agentic Design]]` is orphaned (1 inbound link: index only)

- **Affected**: `wiki/concepts/Agentic Design.md`
- **Problem**: The only inbound link is from `wiki/index.md`. No other page cross-links to it. Given that `[[Agentic Design]]` is a high-value conceptual overview of GAIA's architecture philosophy, it deserves cross-references from the pages it documents: `[[GAIA Philosophy]]`, `[[Claude Integration]]`, `[[Code Review Audit Agent]]`, `[[Task Orchestration]]`.
- **Suggested fix**: Add a `See [[Agentic Design]]` reference or inline link in `[[GAIA Philosophy]]` (the most natural landing point) and/or `[[Claude Integration]]`.

### S3. `wiki/dashboard.md` `## Open Questions` query targets a non-existent folder

- **Affected**: `wiki/meta/dashboard.md`: `## Open Questions` section
- **Problem**: The Dataview query `FROM "wiki/questions"` references a `wiki/questions/` folder that does not exist in this vault. The query will always return empty results in Obsidian and is misleading. The `## Entities Missing Sources` query also targets `sources` frontmatter not used in this vault's entity pages.
- **Suggested fix**: Remove or replace the `## Open Questions` section with a more useful query (e.g. pages updated more than 30 days ago, or pages with status `seed`). Update the `## Entities Missing Sources` query to use a field that actually exists, or remove it.

---

## Checks with clean results

- **Dead wikilinks**: None. `[[CLAUDE]]` appears only in `log.md` historical append-only text (intentional). `[[modules/Claude Integration|...]]` path-style links in `Claude Skills.md` and `Claude Integration Conventions.md` resolve correctly to `modules/Claude Integration.md`. `[[Note Name]]` in `README.md` is documentation prose, not a navigational link. `[[Form Select\|...]]` and `[[Form YearMonthDay\|...]]` table-cell escape syntax is valid Obsidian Markdown.
- **Stale index entries**: All 83 wikilinks in `index.md` resolve to existing files. No stale entries. (Two pages not in index: `README`: W3 above; `lint-report-2026-04-27`: W2 above, created this run.)
- **Orphan pages**: No true 0-inbound-link orphans. Near-orphans (1 inbound link, index only): `Agentic Design` (S2), `dashboard`. `README` has 1 inbound from `log.md` historical text (W3). `lint-report-2026-04-21` and `lint-report-2026-04-26` each have 2 inbound links (index + prior report chain).
- **Required frontmatter** (`type`, `status`, `created`, `updated`, `tags`): All 85 pages pass. `wiki/hot.md` wraps its YAML in an HTML comment block; the YAML is valid and complete.
- **Empty sections**: No genuinely empty sections. The checker flagged several headings whose content lives entirely in sub-headings (e.g. `## The four canonical patterns` in Agentic Design, `## Bundled hooks` in Claude Hooks, `## Four-step protocol` in PR Merge Workflow): all are structurally sound. `## > [!warning]` in Form YearMonthDay is a callout block, not a bare heading.
- **Stale seed pages**: None. No pages carry `status: seed`.
- **Large pages (>300 lines)**: None. Largest: `Agentic Design.md` (140), `Claude Integration.md` (148), `Claude Integration Conventions.md` (165), `MSW Handlers.md` (172).
- **Prior critical issues resolved**: C1 (`Sessions.md` removed-file docs), C2 (`State.md` ThemeProvider architecture), C3 (`Components.md` ThemeSwitcher row) from 2026-04-26 report: all fixed. S2 (unlinked Storybook mentions) partially addressed by the `[[Storybook Stories]]` module page existing; remaining unlinked prose mentions are low-priority.
- **DragonScale**: Not adopted. `scripts/allocate-address.sh` absent, `.vault-meta/address-counter.txt` absent, `scripts/tiling-check.py` absent. Checks 7 and 8 skipped per feature-detection protocol. See [[DragonScale Opt-Out]].
- **Folder naming**: All domain folders lowercase. Convention satisfied.
- **Tag casing**: All tags lowercase across all 85 pages. Convention satisfied.
