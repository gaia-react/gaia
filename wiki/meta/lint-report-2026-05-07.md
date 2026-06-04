---
type: meta
title: 'Lint Report 2026-05-07'
created: 2026-05-07
updated: 2026-05-07
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-05-07

## Summary

- Pages scanned: 93 (excl. 9 meta: 8 lint/consolidate reports + dashboard)
- Issues found: 9 (0 critical, 5 warnings, 4 suggestions)
- Auto-fixed: 0
- Needs review: 9

Domain breakdown: components (6), concepts (28), decisions (10), dependencies (21), entities (2), flows (3), meta (1 dashboard), modules (17), root (5)

DragonScale Mechanism 2 (Address Validation): skipped: `./scripts/allocate-address.sh` or `.vault-meta/address-counter.txt` not present.
DragonScale Mechanism 3 (Semantic Tiling): skipped: `./scripts/tiling-check.py` not present.

**Resolved since 2026-05-06:**

- ✓ [[README]] dead link `[[Note Name]]`: fixed.
- ✓ [[README]] stale `sources/` directory reference: fixed.
- ✓ Missing index entry for `lint-report-2026-05-04`: fixed.
- ✓ YAML `depends_on:` frontmatter parse errors (10 pages): fixed (converted to YAML list format).

---

## Critical (must fix)

None.

---

## Warnings (should fix)

### Empty Sections

Carry-over from prior report: not yet addressed:

1. **[[Agentic Design]]** (`concepts/Agentic Design.md`): 6 empty sub-sections under `## The 12 patterns GAIA implements`: `### Core`, `### Reasoning & Strategy`, `### Orchestration`, `### Infrastructure & State`, `### Reliability & Control`. Structural placeholders. Suggest: fill content or collapse into the parent section with inline notes.

2. **[[PR Merge Workflow]]** (`concepts/PR Merge Workflow.md`): empty section `## Four-step protocol`. Suggest: add the protocol steps or remove the heading.

3. **[[gaia-lint]]** (`dependencies/gaia-lint.md`): empty section `## @gaia-react/lint` (appears as the only heading with no content underneath). Suggest: add a description or merge with the page introduction.

4. **[[GAIA]]** (`entities/GAIA.md`): `# GAIA` heading has no content underneath. The page body is empty after frontmatter. Suggest: add at minimum a one-line description.

### Missing Index Entry

5. **[[consolidate-report-2026-05-07]]**: the file `wiki/meta/consolidate-report-2026-05-07.md` exists on disk but is not listed in `wiki/index.md` under the Meta section. Suggest: add `- [[consolidate-report-2026-05-07]]` to the Meta section of `wiki/index.md`.

---

## Suggestions (worth considering)

### Cross-Reference Gaps: Telemetry (new page)

The new `[[Telemetry]]` page is linked from `wiki/index.md` only. The four pages it cites in its "Pairs with" section do not reciprocally link back:

6. **[[GAIA Spec]]**: mentions `.gaia/local/telemetry/` in two places (lines 19, 35) as plain text. Suggest: add a `[[Telemetry]]` wikilink in the "Pairs with" or a relevant prose mention.

7. **[[GAIA Plan]]**: emits `plan_revised` events per the Telemetry page but does not mention this. Suggest: add a `[[Telemetry]]` reference in the "Pairs with" section.

8. **[[Claude Hooks]]**: referenced as the `PostToolUse Task` hook backstop for engineer-return events, but `Claude Hooks.md` has no mention of the telemetry connection. Suggest: add a note linking to `[[Telemetry]]`.

### Carry-Over Cross-Reference Gaps (high-frequency)

9. **Serena, Conform, Storybook, React Router 7, Playwright, Vitest, Chromatic, i18next**: same unlinked plain-text mentions catalogued in 2026-05-06 report (items 17–24). No new pages added to this set; none addressed yet. See prior report for full page-by-page breakdown.

---

## Orphan Pages

None. Every non-meta page is linked from at least one other page.

## Stale Seed Pages

None. No pages have `status: seed`.

## Stale Index Entries

None. All index.md wikilinks resolve to real files.

## Dead Links

None. All wikilinks in non-meta pages resolve to existing pages.

Note: `[[GAIA Spec\|...]]` and `[[Wiki Sync\|...]]` in `concepts/Wiki Consolidate.md` use backslash-escaped pipe aliases (Obsidian pipe-alias syntax inside a table cell). The link targets `GAIA Spec` and `Wiki Sync` both exist. Not a dead link.

`[[modules/Claude Integration|...]]` in `concepts/Claude Skills.md` and `concepts/Claude Integration Conventions.md` uses a path-qualified wikilink form. The file `wiki/modules/Claude Integration.md` exists. Not a dead link (though path-form links are fragile if the page moves: consider switching to `[[Claude Integration|...]]`).

## Address Validation

Skipped. DragonScale Mechanism 2 not adopted (no `./scripts/allocate-address.sh` or `.vault-meta/address-counter.txt`). See [[DragonScale Opt-Out]].

## Semantic Tiling

Skipped. DragonScale Mechanism 3 not adopted (no `./scripts/tiling-check.py`). See [[DragonScale Opt-Out]].

---

## #11: Wiki drift check

ℹ 1 commit behind HEAD. Run `/wiki-sync` at next opportunity. Recent unsynced commits:

- 33a7d63 wiki: sync through 320335e (1 updated, 3 skipped) (#92)
