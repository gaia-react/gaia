---
type: meta
title: Consolidate Report, 2026-06-24
status: active
created: 2026-06-24
updated: 2026-06-24
tags: [meta, consolidate]
---

# Consolidate Report, 2026-06-24

Run summary: 0 findings across 0 domains.

No supersession candidates, reversed decisions, near-collision slugs, or subject-orphaned pages detected.

**Detection notes:**

- **Supersession (2a):** No pages carry `promoted_from` frontmatter, so the required provenance-gap condition does not hold for any title pair. Pages added since the last run (`Determinism Classifier`, `TDD RED Verification`, `Worthiness Audit`, `Worthiness Presence Gate`, plus updates to `Claude Hooks`, `PR Merge Workflow`, `Routing`, `Playwright`) were evaluated: no title pairs meet Jaccard >= 0.7 threshold. The `Worthiness Audit` vs `Worthiness Presence Gate` pair scores Jaccard = 0.25 (intersection {worthiness} / union {worthiness, audit, presence, gate}).
- **Reversed decisions (2b):** No negation patterns (`no longer use`, `replaces`, `supersedes`, `deprecated in favor of`, `reversed`, `obsoletes`) referencing another decision page's title were found in any decision page body. Uses of "replaces" in `spec-kit Extension Strategy.md` and `Forensics Triage Workflow.md` describe domain concepts, not inter-page supersession.
- **Near-collision slugs (2c):** The `wiki near-collisions --max-distance 2` CLI confirmed zero results across all domains.
- **Subject-orphaned (2d):** The `wiki orphans` CLI returned zero pages with zero inbound links. No candidates to evaluate.
