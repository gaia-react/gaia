---
type: meta
title: Consolidate Report — 2026-05-08
status: active
created: 2026-05-08
updated: 2026-05-08
tags: [meta, consolidate]
---

# Consolidate Report — 2026-05-08

Run summary: 0 findings across 0 domains.

## Notes

- Supersession candidates (2a): zero — no pages carry `promoted_from` frontmatter in canonical domains; provenance-gap condition cannot be met.
- Reversed decisions (2b): zero — no negation phrases in any decision page reference another decision page's title.
- Near-collision slugs (2c): zero — no unacknowledged near-collisions detected. The `Git Workflow` vs `Init Workflow` pair from the 2026-05-07 run remains suppressed via `consolidation_ack: [Git Workflow]` on `Init Workflow`. The `Code Review Audit Agent` vs `Code Review Audit CI` pair (Jaccard 0.75 on title tokens) does not qualify as a supersession candidate (no `promoted_from` on either page) and does not qualify as a near-collision (Levenshtein distance > 2; neither slug is a prefix of the other).
- Subject-orphaned pages (2d): zero — all pages with zero inbound wikilinks were last touched within 17 days; the 90-day threshold is not met. (All canonical-domain pages have at least one inbound wikilink.)
