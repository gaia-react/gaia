---
type: meta
title: Consolidate Report, 2026-07-21
status: active
created: 2026-07-21
updated: 2026-07-21
tags: [meta, consolidate]
---

# Consolidate Report, 2026-07-21

Run summary: 0 findings across 0 domains.

No supersession candidates, reversed decisions, near-collision slugs, or subject-orphaned pages detected in this run.

- 2a (supersession): no page in a canonical domain (`decisions`, `concepts`, `modules`, `flows`, `components`, `dependencies`) carries `promoted_from`/`promoted_at` frontmatter, so the provenance-gap condition cannot be evaluated. 0 candidates.
- 2b (reversed decisions): same provenance gap, `wiki/decisions/` pages have no `promoted_at` to establish a newer/older ordering. 0 candidates.
- 2c (near-collision slugs): `gaia wiki near-collisions --max-distance 2` returned no pairs.
- 2d (subject-orphaned pages): `gaia wiki orphans` returned zero pages with no inbound links.
