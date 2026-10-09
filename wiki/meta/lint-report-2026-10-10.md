---
type: meta
title: 'Lint Report 2026-10-10'
created: 2026-10-10
updated: 2026-10-10
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-10-10

## #11: Wiki drift check

⚠ `wiki/.state.json` `last_evaluated_sha` (`d4a23fc`) is not reachable from HEAD (squashed/rewritten history). Run `/gaia-wiki`: its sync stage resolves a recovery baseline (`b9eda93`) and evaluates the un-evaluated window.

## #12: Dead repo-relative paths

✓ No dead repo-relative paths detected in wiki body prose.

## #13: UAT/SPEC narrative-ref drift

✓ No narrative `UAT-NNN` or concrete maintainer `SPEC-NNN` references detected outside the structural exemptions in `.claude/rules/wiki-style.md`.

## #14: Orphan pages

✓ No orphan pages (every page has at least one inbound wikilink).

## #15: Frontmatter gaps

✓ All wiki pages carry the required frontmatter (type, status).

## #16: Empty sections

✓ No empty sections detected.

## #17: Broken wikilinks

✓ No broken wikilinks detected.
