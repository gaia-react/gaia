---
type: meta
title: 'Lint Report 2026-05-06'
created: 2026-05-06
updated: 2026-05-06
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-05-06

## Summary

- Pages scanned: 92 (excl. 6 prior lint reports)
- Issues found: 26 (3 critical, 14 warnings, 9 suggestions)
- Auto-fixed: 0
- Needs review: 26

Domain breakdown: components (6), concepts (27), decisions (10), dependencies (21), entities (2), flows (3), meta (1), modules (17), root (5)

DragonScale Mechanism 2 (Address Validation): skipped: `./scripts/allocate-address.sh` or `.vault-meta/address-counter.txt` not present.
DragonScale Mechanism 3 (Semantic Tiling): skipped: `./scripts/tiling-check.py` not present.

---

## Critical (must fix)

### Dead Links

1. **[[README]]**: contains `[[Note Name]]`: a placeholder link left over from the wiki schema template. No page named "Note Name" exists. Suggest: remove or replace with a real wikilink.

### Stale Index Entries

No stale index entries found. All index.md wikilinks resolve to real files.

### Missing Index Entry

2. **[[lint-report-2026-05-04]]**: the file `wiki/meta/lint-report-2026-05-04.md` exists on disk but is not listed in `wiki/index.md` under the Meta section. The five earlier reports are listed; this one was omitted. Suggest: add `- [[lint-report-2026-05-04]]` to the Meta section of `wiki/index.md`.

---

## Warnings (should fix)

### Frontmatter YAML Parse Errors

The `depends_on:` field uses comma-separated wikilinks (`[[A]], [[B]]`). YAML parses the `[[A]]` anchor as a merge key, then chokes on the `,`. All required fields (type, status, created, updated, tags) are present in raw text, so the pages are functionally usable in Obsidian: but any tooling that reads frontmatter via a YAML parser will fail on these 10 pages.

Fix: quote the value or convert to a YAML list:

```yaml
# Option A: quoted string (minimal change)
depends_on: "[[Form Components]], [[Form Field]]"

# Option B: YAML list
depends_on:
  - "[[Form Components]]"
  - "[[Form Field]]"
```

Affected pages (10):

3. **[[Form Choices]]** (`components/Form Choices.md`): `depends_on: [[Form Components]], [[Form Field]]`
4. **[[Form Select]]** (`components/Form Select.md`): `depends_on: [[Form Components]], [[Form Field]]`
5. **[[Form Text Inputs]]** (`components/Form Text Inputs.md`): `depends_on: [[Form Components]], [[Form Field]]`
6. **[[Form YearMonthDay]]** (`components/Form YearMonthDay.md`): `depends_on: [[Form Select]], [[Conform]], [[Form Components]]`
7. **[[Form Components]]** (`modules/Form Components.md`): `depends_on: [[Conform]], [[Zod]]`
8. **[[Routing]]** (`modules/Routing.md`): `depends_on: [[remix-flat-routes]], [[React Router 7]]`
9. **[[Services]]** (`modules/Services.md`): `depends_on: [[Ky]], [[Zod]]`
10. **[[Storybook Stories]]** (`modules/Storybook Stories.md`): `depends_on: [[Storybook]], [[MSW]]`
11. **[[Testing]]** (`modules/Testing.md`): `depends_on: [[Vitest]], [[React Testing Library]], [[Playwright]], [[MSW]]`
12. **[[i18n]]** (`modules/i18n.md`): `depends_on: [[remix-i18next]], [[i18next]]`

### Empty Sections

Headings with no content underneath them:

13. **[[Agentic Design]]** (`concepts/Agentic Design.md`): 6 empty sub-sections under `## The 12 patterns GAIA implements`: `#Core`, `#Reasoning & Strategy`, `#Orchestration`, `#Infrastructure & State`, `#Reliability & Control`. These are structural placeholders. Suggest: fill content or collapse into the parent section with inline notes.

14. **[[PR Merge Workflow]]** (`concepts/PR Merge Workflow.md`): empty section `## Four-step protocol`. Suggest: add the protocol steps or remove the heading.

15. **[[gaia-lint]]** (`dependencies/gaia-lint.md`): empty section `## @gaia-react/lint`. Suggest: add a description or merge with the page introduction.

16. **[[GAIA]]** (`entities/GAIA.md`): the heading `# GAIA` has no content underneath it. The page body appears to be empty after the frontmatter. Suggest: add at minimum a one-line description.

Excluded from "empty section" findings (by design): `hot.md` (`#Recent Context` is cleared by Stop hook), `log.md` (`#Log` gets entries prepended), `meta/dashboard.md` (`#Wiki Dashboard` contains only Dataview blocks which are non-empty markup).

---

## Suggestions (worth considering)

### Cross-Reference Gaps

Entities with dedicated wiki pages referenced by plain text (no `[[` brackets) in other pages. These are unlinked mentions: not broken, but cross-navigation is weaker without the link.

High-frequency unlinked mentions (appearing in 4+ pages without wikilinks):

17. **Serena**: mentioned without wikilink in: `Form Choices`, `Form Field`, `Form Layout`, `Form Select`, `Form Text Inputs`, `Form YearMonthDay`, `Component Testing`, `Serena Integration`. The `[[Serena]]` dependency page exists. Suggest: add `[[Serena]]` wikilinks in the component pages and `Component Testing`.

18. **Conform**: mentioned without wikilink in: `Form Choices`, `Form Select`, `Form Text Inputs`, `Dark Mode Modernization`, `No Component Library`, `Component Testing`, `Thin Routes`, `composeStory Pattern`, `GAIA Philosophy`. The `[[Conform]]` dependency page exists. Suggest: linkify high-value mentions.

19. **Storybook**: mentioned without wikilink in: `Co-located Tests Folder`, `Dark Mode Modernization`, `No Component Library`, `Thin Routes`, `composeStory Pattern`, `Component Testing`, `Chromatic`, `MSW`, `knip`. The `[[Storybook]]` dependency page exists.

20. **React Router 7**: mentioned without wikilink in: `Playwright`, `remix-flat-routes`, `remix-i18next`. The `[[React Router 7]]` dependency page exists.

21. **Playwright**: mentioned without wikilink in: `Coding Guidelines`, `GAIA Spec`, `Quality Gate`, `TypeScript Language Files`. The `[[Playwright]]` dependency page exists.

22. **Vitest**: mentioned without wikilink in: `Coding Guidelines`, `Pre-commit Hooks`, `Claude Skills`. The `[[Vitest]]` dependency page exists.

23. **Chromatic**: mentioned without wikilink in: `Component Testing`, `composeStory Pattern`. The `[[Chromatic]]` dependency page exists.

24. **i18next**: mentioned without wikilink in: `remix-i18next`, `Storybook`. The `[[i18next]]` dependency page exists.

### Missing Concept Pages

25. **"React Context"**: mentioned in 3 pages (`API Service Pattern`, `State`, `overview`) without a dedicated wiki page. It is a React primitive used in the state architecture. Low priority given it is framework-standard knowledge, but a stub under `wiki/concepts/` would anchor cross-references.

### Stale Claims

26. **[[README]]** (`wiki/README.md`): frontmatter `updated: 2026-04-21`. The README references `wiki/sources/` as a subdirectory in the structure diagram, but no `sources/` folder exists on disk (no files were ever ingested there). The diagram shows it as a real path. Suggest: remove the `sources/` line from the structure diagram or note it as "unused / future use".

---

## Orphan Pages

None. Every non-meta page is linked from at least one other page.

## Stale Seed Pages

None. No pages have `status: seed`.

## Address Validation

Skipped. DragonScale Mechanism 2 not adopted (no `./scripts/allocate-address.sh` or `.vault-meta/address-counter.txt`). See [[DragonScale Opt-Out]].

## Semantic Tiling

Skipped. DragonScale Mechanism 3 not adopted (no `./scripts/tiling-check.py`). See [[DragonScale Opt-Out]].
