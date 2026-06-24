---
type: meta
title: Consolidate Report, 2026-06-23
status: active
created: 2026-06-23
updated: 2026-06-23
tags: [meta, consolidate]
---

# Consolidate Report, 2026-06-23

Run summary: 0 findings across 0 domains.

No supersession candidates, reversed decisions, near-collision slugs, or subject-orphaned pages detected.

**Detection notes:**

- **Supersession (2a):** No pages carry `promoted_from` frontmatter, so the required provenance-gap condition does not hold for any title pair. The `Code Review Audit Agent` vs `Code Review Audit CI` pair (concepts, Jaccard = 0.75) was re-evaluated and again excluded for lack of provenance data. No new title pairs meet Jaccard >= 0.7 threshold among the newly added pages (`Determinism Classifier`, `Worthiness Audit`, `Worthiness Presence Gate`, `react-doctor`, `pnpm-overrides`).
- **Reversed decisions (2b):** No negation patterns (`no longer use`, `replaces`, `supersedes`, `deprecated in favor of`, `reversed`, `obsoletes`) referencing another decision page's title were found in any decision page body. Uses of "replaces" in `spec-kit Extension Strategy.md` and `Forensics Triage Workflow.md` describe domain concepts, not inter-page supersession.
- **Near-collision slugs (2c):** No slug pairs within Levenshtein distance 2 or prefix-relationship found across any domain. The `wiki near-collisions --max-distance 2` CLI confirmed zero results, and manual slug-pair analysis corroborates this.
- **Subject-orphaned (2d):** The `wiki orphans` CLI returned zero pages with zero inbound links. No candidates to evaluate.
