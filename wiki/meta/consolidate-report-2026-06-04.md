---
type: meta
title: Consolidate Report — 2026-06-04
status: active
created: 2026-06-04
updated: 2026-06-04
tags: [meta, consolidate]
---

# Consolidate Report — 2026-06-04

Run summary: 0 findings across 0 domains.

No supersession candidates, reversed decisions, near-collision slugs, or subject-orphaned pages detected.

**Detection notes:**

- **Supersession (2a):** One title pair met the Jaccard ≥ 0.7 threshold (`Code Review Audit Agent` vs `Code Review Audit CI`, Jaccard = 0.75), but neither page carries `promoted_from` frontmatter, so the required provenance gap condition does not hold. Not flagged.
- **Reversed decisions (2b):** No negation patterns (`replaces`, `supersedes`, `no longer use`, `deprecated in favor of`, `reversed`, `obsoletes`) referencing another decision page's title were found in any decision page body.
- **Near-collision slugs (2c):** No slug pairs within Levenshtein distance 2 or prefix-relationship found across any domain.
- **Subject-orphaned (2d):** 24 pages have zero inbound wikilinks, but none have been untouched for 90+ days (oldest is 44 days). The 90-day threshold was not met by any candidate.
