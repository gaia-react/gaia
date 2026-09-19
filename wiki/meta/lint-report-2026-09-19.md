---
type: meta
title: 'Lint Report 2026-09-19'
created: 2026-09-19
updated: 2026-09-19
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-09-19

## #11: Wiki drift check

ℹ 1 commits behind HEAD. Run /gaia-wiki sync at next opportunity.

## #12: Dead repo-relative paths

✓ No dead repo-relative paths detected in wiki body prose.

## #13: UAT/SPEC narrative-ref drift

⚠        8 narrative ref(s) found in instruction files / shipped extension surfaces:

- `.claude/skills/gaia/references/wiki/lint.md:208` → - **Flag (narrative, findings):** section-header parentheticals (`#### 5b. Discuss-this escape (UAT-004)`), inline narrative parentheticals (`(UAT-022, UAT-027)`), comments naming specific working-doc IDs, pass/fail label prefixes (`pass "UAT-001 …"`), prose using a maintainer SPEC ID as a system-wide constant (`operate under SPEC-001's scope_boundaries`).
- `.claude/skills/gaia/references/wiki/lint.md:225` → - `.claude/skills/foo/SKILL.md:42` → `(UAT-012)` parenthetical in section header
- `.claude/rules/wiki-style.md:27` → - **No UAT or SPEC references in prose or comments.** `UAT-NNN` identifies entries inside SPECs; `SPEC-NNN` identifies the SPECs themselves. Both are working documents, they get superseded, renumbered, or deleted. A reader querying the wiki about a feature gets no value from "implements UAT-012" or "from SPEC-005". Drop the reference; describe what the feature does and why.

## #14: Orphan pages

✓ No orphan pages (every page has at least one inbound wikilink).

## #15: Frontmatter gaps

✓ All wiki pages carry the required frontmatter (type, status).

## #16: Empty sections

✓ No empty sections detected.
