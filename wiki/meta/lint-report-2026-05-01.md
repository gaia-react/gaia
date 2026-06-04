---
type: meta
title: 'Lint Report 2026-05-01'
created: 2026-05-01
updated: 2026-05-01
tags: [meta, lint]
status: active
---

# Wiki Lint Report: 2026-05-01

Run after commits: `17a2444` (chore: restructure commands, skills, and rules) and `7cae765` (feat: replace FontAwesome with react-icons), both 2026-05-01. Previous report: [[lint-report-2026-04-27]].

## Summary

- Pages scanned: 87
- Issues found: 8 (1 critical, 4 warnings, 3 suggestions)
- Auto-fixed: 21 (stale frontmatter)
- DragonScale: not adopted: checks 9 and 10 skipped

---

## Prior Report Resolution

| Issue                                                   | Status                                                            |
| ------------------------------------------------------- | ----------------------------------------------------------------- |
| C1: six stale `updated:` pages                          | ✓ Fixed                                                           |
| C2: `overview.md` stale State/pages claims              | ✓ Fixed                                                           |
| W1: `hot.md` stale branch claim                         | ✓ Fixed                                                           |
| W2: `index.md` missing `lint-report-2026-04-27`         | ✓ Fixed                                                           |
| W3: `README` not in `index.md`                          | ✓ Fixed                                                           |
| W4: `log.md` missing `@msw/data` entry                  | ✗ Not fixed; log format changed to release-only (see C1 below)    |
| S1: no `@msw/data` dependency page                      | Not addressed (optional)                                          |
| S2: `[[Agentic Design]]` near-orphan                    | Improved: now linked from `[[GAIA Philosophy]]` (3 inbound links) |
| S3: `dashboard.md` non-existent `wiki/questions/` query | ✓ Fixed                                                           |

---

## Critical (must fix)

### C1. 19 wiki pages have stale `updated:` frontmatter after 2026-05-01 edits

Both `17a2444` (restructure) and `7cae765` (react-icons) ran on 2026-05-01 but the `updated:` field was not bumped on the pages they touched.

**Affected pages:**

- `wiki/concepts/Agentic Design.md`: `2026-04-29`
- `wiki/concepts/Claude Hooks.md`: `2026-04-30`
- `wiki/concepts/Claude Integration Conventions.md`: `2026-04-30`
- `wiki/concepts/Claude Skills.md`: `2026-04-30`
- `wiki/concepts/GAIA Audit.md`: `2026-04-30`
- `wiki/concepts/GAIA Handoff.md`: `2026-04-30`
- `wiki/concepts/GAIA Pickup.md`: `2026-04-30`
- `wiki/concepts/GAIA Plan.md`: `2026-04-30`
- `wiki/concepts/Release Workflow.md`: `2026-04-22`
- `wiki/concepts/Task Orchestration.md`: `2026-04-30`
- `wiki/concepts/Update Workflow.md`: `2026-04-22`
- `wiki/decisions/Quality Gate.md`: `2026-04-30`
- `wiki/decisions/Thin Routes.md`: `2026-04-20`
- `wiki/decisions/pnpm.md`: `2026-04-26`
- `wiki/index.md`: `2026-04-30`
- `wiki/modules/Claude Integration.md`: `2026-04-30`
- `wiki/modules/Pages.md`: `2026-04-20`
- `wiki/overview.md`: `2026-04-27`
- `wiki/sources/Initial Ingest.md`: `2026-04-20`

**Suggested fix:** Set `updated: 2026-05-01` on all 19 files. **Auto-fixed in this run.**

Also related:

- `wiki/log.md` has **no frontmatter at all**: was reset as part of `17a2444`. Add frontmatter with `type: meta`, `status: active`, `created: 2026-04-20`, `updated: 2026-05-01`, `tags: [meta]`. **Auto-fixed.**
- `wiki/hot.md` missing `created`, `status`, `tags` fields. **Auto-fixed.**
- `wiki/meta/dashboard.md` `updated:` is stale at `2026-04-27` (S3 was fixed in an earlier session). **Auto-fixed.**

---

## Warnings (should fix)

### W1. `wiki/index.md` missing entry for `lint-report-2026-05-01`

This report has no entry yet. **Suggested fix:** Add `- [[lint-report-2026-05-01]]` to the `## Meta` section of `wiki/index.md`. Auto-fix after report is written.

### W2. `wiki/log.md` content is missing the `@msw/data` migration and restructure entries

The log was reset in `17a2444` to just version release entries, losing the detailed ingest log. W4 from the 2026-04-27 report is now permanently unaddressed. The current log only has `## [v1.0.3] 2026-05-01 | Released`. There are no entries for: `@msw/data` migration (2026-04-27), dark mode modernization (2026-04-26), pnpm migration (2026-04-26), or the claude restructure (2026-05-01).

**Suggested fix:** Add brief log entries for the major milestones that occurred between the last log entry and the reset, or accept the reset as intentional and note in README that the log now tracks releases only.

### W3. `[[Handoff Command]]`, `[[Pickup Command]]`, `[[Audit-Knowledge Command]]` renamed: verify no stale prose references

These pages were deleted in `17a2444` and replaced by `[[GAIA Handoff]]`, `[[GAIA Pickup]]`, `[[GAIA Audit]]`. All wikilinks are clean (grep confirmed no dangling references). However, **prose** in other docs (not wiki) may still say "Handoff Command" or similar. Out of lint scope, but worth a search.

### W4. `wiki/hot.md` does not reference any active thread

`hot.md` currently reads "Active Threads: None." after a v1.0.3 release. This is valid post-release, but should be updated at the start of the next work session to reflect the next active branch/context.

---

## Suggestions (worth considering)

### S1. `@msw/data` still has no dedicated dependency page (carried from 2026-04-27)

Referenced in seven pages. Low priority given thorough coverage in `[[MSW Handlers]]`. Optional: create `wiki/dependencies/@msw-data.md`.

### S2. `[[Agentic Design]]` inbound links still sparse

Now has 3 inbound (index, `[[GAIA Philosophy]]`, `[[lint-report-2026-04-27]]`). The 2026-04-27 lint report link is historical text, not a meaningful navigation point. `[[Claude Integration]]` and `[[Task Orchestration]]` would be natural landing points. Consider adding a `See also: [[Agentic Design]]` line to those pages.

### S3. `[[dashboard]]` is an index-only page

Only inbound link is `wiki/index.md`. No other wiki page links to it. Not a problem in practice since Obsidian meta pages are navigated directly, but worth noting.

---

## Checks with clean results

- **Dead wikilinks:** None. `[[CLAUDE]]` in `log.md` is historical (intentional). `[[modules/Claude Integration|...]]` path-style links in `Claude Skills.md` and `Claude Integration Conventions.md` resolve correctly. `[[Note Name]]` in `README.md` is documentation prose.
- **Stale index entries:** All wikilinks in `index.md` resolve to existing files. `[[FontAwesome]]` removed from index in `7cae765` ✓.
- **Orphan pages:** No 0-inbound-link orphans. Near-orphans (index only): `[[dashboard]]` (S3), `[[Initial Ingest]]`, all lint reports.
- **Required frontmatter (`type`, `status`, `created`, `updated`, `tags`):** After auto-fixes, all pages pass.
- **Empty sections:** None.
- **Folder naming:** All domain folders lowercase ✓.
- **Tag casing:** All tags lowercase ✓.
- **Renames (`Handoff Command` → `GAIA Handoff`, etc.):** No dangling wikilinks ✓.
- **DragonScale:** Not adopted. Checks 9–10 skipped.
- **Semantic tiling:** `scripts/tiling-check.py` absent. Skipped.
