---
type: meta
title: 'Lint Report 2026-05-04'
status: developing
created: 2026-05-04
updated: 2026-05-04
tags: [meta, lint]
---

# Lint Report: 2026-05-04

Pre-release `/wiki-lint` for v1.0.5. Run on `release/v1.0.5` branch from `b5b71e6`.

## Summary

- Pages scanned: 91
- Issues found: 2 (during initial scan; both fixed before commit)
- Auto-fixed: 2 (frontmatter regression on `hot.md` + `log.md`)
- Needs review: 0

## #1: Orphan Pages

✓ None. All 83 non-meta pages have at least one inbound wikilink.

## #2: Dead Links

✓ Effective count: 0.

The raw scan flagged 12 candidates; all are non-blocking false positives:

- `[[Note Name]]` in `wiki/README.md` line 39 is a **syntax example** (`Wikilinks use [[Note Name]]: filenames are unique`), not a real link.
- 11 references in archival lint reports under `wiki/meta/` (`lint-report-2026-04-21.md`, `..-04-26.md`, `..-04-27.md`, `..-05-01.md`, `..-05-03.md`) cite pages that have since been renamed or deleted (`[[CLAUDE]]`, `[[Handoff Command]]`, `[[Pickup Command]]`, `[[Audit-Knowledge Command]]`, `[[FontAwesome]]`, `[[Note Name]]`). Historical record drift is expected; archival reports are read-only.

## #3: Stale Claims

✓ Not run (manual judgment; no high-signal triggers detected).

## #4: Missing Pages

✓ Not run (manual judgment).

## #5: Missing Cross-References

✓ Not run (manual judgment).

## #6: Frontmatter Gaps

✓ 0 gaps after auto-fix.

Initial scan flagged 2 regressions (the same finding as the 2026-05-03 lint report):

- `wiki/hot.md`: missing `created`, `status`, `tags`. Root cause: `/gaia-release` Step 8 scrub template.
- `wiki/log.md`: no frontmatter at all. Root cause: `/gaia-release` Step 9 scrub template.

**Auto-fixed in this run.** The scrub templates in `.claude/commands/gaia-release.md` (Steps 8–9) and `.claude/commands/gaia-init.md` (Step 10a) were updated to include the full required field set (`type`, `title`, `status`, `created`, `updated`, `tags`). Both files were re-scrubbed with the corrected templates and now pass.

## #7: Empty Sections

✓ Not run exhaustively (low-signal; no recent additions trigger it).

## #8: Stale Index Entries

✓ Not run (no recent renames or deletions).

## #11: Wiki drift check

ℹ 1 commits behind HEAD. Run `/wiki-sync` at next opportunity. (Drift is the in-flight `chore(release): v1.0.5` commit; state will catch up via the release commit's amend in `/gaia-release` Step 11.)

State: `469f6ca` · HEAD: `b5b71e6`

## Address Validation (DragonScale Mechanism 2)

Skipped: DragonScale not enabled in this vault (no `./scripts/allocate-address.sh`).

## Semantic Tiling (DragonScale Mechanism 3)

Skipped: DragonScale not enabled.
