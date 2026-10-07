---
type: meta
title: 'Lint Report 2026-10-07'
created: 2026-10-07
updated: 2026-10-07
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-10-07

## #11: Wiki drift check

✓ Wiki in sync with HEAD (1878805).

## #12: Dead repo-relative paths

⚠ 5 dead path reference(s) in wiki/, files no longer exist on disk:

- `wiki/concepts/Data Loading.md:85` → `frontend/app/query-client.ts`
- `wiki/concepts/Data Loading.md:87` → `frontend/app/state/query-provider.tsx`
- `wiki/decisions/Dependabot Security Updates.md:25` → `.gaia/cli/src/setup-ci/write-dependabot-config.ts`
- `wiki/dependencies/react-doctor.md:43` → `.claude/hooks/react-doctor.mjs`
- `wiki/modules/State.md:20` → `frontend/app/state/query-provider.tsx`

## #13: UAT/SPEC narrative-ref drift

✓ No narrative `UAT-NNN` or concrete maintainer `SPEC-NNN` references detected outside the structural exemptions in `.claude/rules/wiki-style.md`.

## #14: Orphan pages

✓ No orphan pages (every page has at least one inbound wikilink).

## #15: Frontmatter gaps

✓ All wiki pages carry the required frontmatter (type, status).

## #16: Empty sections

⚠ 1 empty section(s):

- `wiki/index.md:44` → `## Components`
