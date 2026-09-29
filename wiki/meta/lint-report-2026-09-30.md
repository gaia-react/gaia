---
type: meta
title: 'Lint Report 2026-09-30'
created: 2026-09-30
updated: 2026-09-30
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-09-30

## #11: Wiki drift check

ℹ 1 commits behind HEAD. Run /gaia-wiki sync at next opportunity.

## #12: Dead repo-relative paths

⚠ 3 dead path reference(s) in wiki/, files no longer exist on disk:

- `wiki/decisions/Dark Mode Modernization.md:26` → `app/routes/resources+/theme-switch.tsx`
- `wiki/modules/Routing.md:31` → `app/routes/_session.tsx`
- `wiki/modules/Sessions.md:24` → `app/routes/_session.tsx`

## #13: UAT/SPEC narrative-ref drift

✓ No narrative `UAT-NNN` or concrete maintainer `SPEC-NNN` references detected outside the structural exemptions in `.claude/rules/wiki-style.md`.

## #14: Orphan pages

✓ No orphan pages (every page has at least one inbound wikilink).

## #15: Frontmatter gaps

✓ All wiki pages carry the required frontmatter (type, status).

## #16: Empty sections

✓ No empty sections detected.
