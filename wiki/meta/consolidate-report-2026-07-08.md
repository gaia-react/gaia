---
type: meta
title: Consolidate Report, 2026-07-08
status: active
created: 2026-07-08
updated: 2026-07-08
tags: [meta, consolidate]
---

# Consolidate Report, 2026-07-08

Run summary: 0 findings across 0 domains.

No supersession candidates, reversed decisions, near-collision slugs, or subject-orphaned pages detected.

**Detection notes:**

- **Supersession (2a):** No pages carry `promoted_from` frontmatter (0 of 152 indexed pages), so the required provenance-gap condition does not hold for any title pair. The one page added since the last run (`OS Sandbox`) was evaluated: no title pairs meet the Jaccard >= 0.7 threshold against existing `concepts` pages.
- **Reversed decisions (2b):** No negation patterns (`no longer use`, `replaces`, `supersedes`, `deprecated in favor of`, `reversed`, `obsoletes`) referencing another decision page's title were found in any decision page body. The three "replaces" matches in `spec-kit Extension Strategy.md` and one in `Forensics Triage Workflow.md` describe domain concepts (preset/template replacement, label replacement), not inter-page supersession.
- **Near-collision slugs (2c):** The `wiki near-collisions --max-distance 2` CLI returned zero results across all domains.
- **Subject-orphaned (2d):** The `wiki orphans` CLI returned zero pages with zero inbound links. No candidates to evaluate.
