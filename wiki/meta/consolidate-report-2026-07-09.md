---
type: meta
title: Consolidate Report, 2026-07-09
status: active
created: 2026-07-09
updated: 2026-07-09
tags: [meta, consolidate]
---

# Consolidate Report, 2026-07-09

Run summary: 0 findings across 0 domains.

No supersession candidates, reversed decisions, near-collision slugs, or subject-orphaned pages detected.

**Detection notes:**

- **Supersession (2a):** No pages carry `promoted_from` frontmatter (0 of 115 indexed pages across the six canonical domains), so the required provenance-gap condition does not hold for any title pair. `.gaia/cli/gaia wiki page-index --json` currently returns 155 entries including `wiki/meta/` and `wiki/entities/` pages, which the playbook documents as excluded from the index; those were filtered out before running the domain-scoped comparison.
- **Reversed decisions (2b):** No negation patterns (`no longer use`, `replaces`, `supersedes`, `deprecated in favor of`, `reversed`, `obsoletes`) referencing another decision page's title were found in any decision page body. The `replaces` matches in `spec-kit Extension Strategy.md` and `Forensics Triage Workflow.md` describe domain concepts (preset/template replacement, label replacement), not inter-page supersession.
- **Near-collision slugs (2c):** `.gaia/cli/gaia wiki near-collisions --max-distance 2` returned zero results across all domains; confirmed independently via a manual Levenshtein pass over all per-domain slug pairs.
- **Subject-orphaned (2d):** `.gaia/cli/gaia wiki orphans --json` returned zero pages with zero inbound links. No candidates to evaluate.
