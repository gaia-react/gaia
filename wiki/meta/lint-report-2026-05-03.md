---
type: meta
title: 'Lint Report 2026-05-03'
created: 2026-05-03
updated: 2026-05-03
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-05-03

Run after `/wiki-sync` backfill from v1.0.0 baseline through v1.0.5 + smoke fix (range `baa58d9..6686f26`, 23 non-merge commits, 6 worthy + 17 skipped). Three concept pages updated by sync: `Claude Hooks.md`, `Release Workflow.md`, `GAIA Audit.md`.

## Summary

- Pages scanned: 86 (excluding meta + this report)
- Issues found: 4
- Auto-fixed: 0
- Needs review: 4

## Orphan Pages

None. Every concept, decision, dependency, component, flow, module, and entity page has at least one inbound wikilink.

## Dead Links

No active dead links. Historical references to removed pages (`Audit-Knowledge Command`, `Pickup Command`, `Handoff Command`, `FontAwesome`, `[[CLAUDE]]`) live only inside archival lint reports under `wiki/meta/lint-report-*.md` — these are append-only records, not navigational links.

False positives surfaced and dismissed:

- `[[Form Select\|Select]]` and `[[Form YearMonthDay\|YearMonthDay]]` in `Form Field.md` and `Form Select.md` — valid Obsidian table-cell pipe escapes. Targets exist.
- `[[modules/Claude Integration|...]]` in `Claude Skills.md` and `Claude Integration Conventions.md` — valid path-prefixed wikilinks. Target `wiki/modules/Claude Integration.md` exists.
- `[[Note Name]]` in `wiki/README.md:39` — documentation prose explaining wikilink format, not a link.

## Frontmatter Gaps

- **`wiki/hot.md`**: missing `status`, `created`, `tags`.
- **`wiki/log.md`**: missing the frontmatter block entirely.

> [!note] Recurring regression
> Both files were correctly populated by the 2026-05-01 audit hygiene sweep (commit 0307c3d). They get reset every release: `/gaia-release` Steps 8–9 overwrite both files with release-baseline content that lacks the canonical fields. Tracked separately — fix lives in `.claude/commands/gaia-release.md`, not in this lint pass.

## Empty Sections

- **`wiki/components/Form YearMonthDay.md:34`**: heading `## > [!warning] Conform integration — two non-obvious gotchas` has a stray `>` prefix in the heading text. Likely an `H2` + adjacent callout that got merged on edit. Should be either:

  ```markdown
  ## Conform integration — two non-obvious gotchas

  > [!warning]
  > ...
  ```

  or just a top-level callout with no `## `.

(Other matches from the empty-section scan were false positives — H2 parents whose content is delegated to H3 children, e.g. `## The 12 patterns GAIA implements` in `Agentic Design.md`. Legitimate structural pattern.)

## Stale Index Entries

None. All 86 entries in `wiki/index.md` resolve to existing pages.

## Cross-Reference Gaps

Not exhaustively audited this pass. Targeted spot-check: `Wiki Sync.md` correctly cross-links `[[Quality Gate]]`, `[[GAIA Plan]]`, `[[Release Workflow]]`, `[[Claude Hooks]]` — all four resolve.

## Stale Claims

None surfaced. The three pages updated by `/wiki-sync` (`Claude Hooks.md`, `Release Workflow.md`, `GAIA Audit.md`) are now consistent with code at HEAD; the remaining 83 pages are unchanged from prior lint runs and reflect their last verified state.

## Address Validation

Skipped — DragonScale not enabled (`scripts/allocate-address.sh` not present).

## Semantic Tiling

Skipped — `scripts/tiling-check.py` not present.

## State

`wiki/.state.json` `last_evaluated_sha` = `6686f26305338b14990079383e236fe4af300b34` (matches HEAD on `main` at the time of the upstream `/wiki-sync` run). HEAD at lint time is 1 commit ahead — the in-flight `wiki: sync through 6686f26` commit on `wiki/backfill-v1.0.5` itself. State will catch up after PR #72 merges.

## Action items

1. Decide whether to fix the malformed `## > [!warning]` heading in `Form YearMonthDay.md:34` — single-page edit.
2. Patch `/gaia-release` Steps 8–9 to preserve `hot.md` and `log.md` frontmatter on release scrub. Recurring root-cause; should be a separate PR (touches `.claude/commands/gaia-release.md`).
