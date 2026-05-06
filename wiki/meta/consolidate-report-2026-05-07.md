---
type: meta
title: Consolidate Report — 2026-05-07
status: active
created: 2026-05-07
updated: 2026-05-07
tags: [meta, consolidate]
---

# Consolidate Report — 2026-05-07

Run summary: 0 findings across 6 domains.

## Notes

All four detection passes returned zero findings:

- **Supersession candidates (2a):** Zero pages carry `promoted_from` frontmatter (only `wiki/concepts/Wiki Consolidate.md` references `promoted_from` in its prose body, not frontmatter). No same-domain title-similarity pairs with provenance gaps exist.
- **Reversed decisions (2b):** No negation phrases (`no longer use`, `replaces`, `supersedes`, `deprecated in favor of`, `reversed`, `obsoletes`) appear in any decision page body referencing another decision page's title.
- **Near-collision slugs (2c):** No same-domain slug pairs have Levenshtein distance ≤ 3 or prefix overlap with length difference ≥ 3. Candidates investigated: `remix-flat-routes` / `remix-i18next` / `remix-toast` (all distance > 3), `GAIA Audit` / `GAIA Handoff` / `GAIA Pickup` / `GAIA Plan` / `GAIA Spec` (GAIA-prefix shared but suffix distance > 3), `Wiki Consolidate` / `Wiki Sync` (Wiki-prefix shared but "Consolidate" ≠ "Sync" and neither is a prefix of the other). `Chromatic Opt-Out` (concepts) vs `DragonScale Opt-Out` (decisions) are different domains — excluded.
- **Subject-orphaned pages (2d):** All 85 pages were last touched between 2026-04-20 and 2026-05-07 (≤ 17 days ago). The 90-day threshold for subject-orphan candidacy is not met by any page.
