---
type: meta
title: 'Lint Report 2026-07-01'
created: 2026-07-01
updated: 2026-07-01
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-07-01

## #11: Wiki drift check

ℹ 2 commits behind HEAD. Run /gaia-wiki sync at next opportunity.

## #12: Dead repo-relative paths

⚠ 1 dead path reference(s) in wiki/, files no longer exist on disk:

- `wiki/decisions/Dark Mode Modernization.md:30` → `app/components/Header/index.tsx`

## #13: UAT/SPEC narrative-ref drift

✓ No narrative `UAT-NNN` or concrete maintainer `SPEC-NNN` references detected outside the structural exemptions in `.claude/rules/wiki-style.md`.

## #14: Orphan pages

✓ No orphan pages (every page has at least one inbound wikilink).

## #15: Frontmatter gaps

✓ All wiki pages carry the required frontmatter (type, status).

## #16: Empty sections

✓ No empty sections detected.
