---
paths:
  - 'wiki/**/*.md'
  - 'app/**/*.{ts,tsx,js,jsx,css}'
---

# Wiki & Comment Style

Body prose and code comments describe **what is** in present tense. The historical record lives in git (`git log`, `git blame`), `wiki/log.md`, and `CHANGELOG.md` — body prose is not the place for it.

## Rules

- **Present tense only.** Do not write "was changed from X to Y", "previously did A, now does B", "moved from a to b". State the current behavior directly.
- **No UAT references in prose or comments.** `UAT-NNN` identifies entries inside SPECs — working documents that get superseded, renumbered, or deleted. A reader querying the wiki about a feature gets no value from "implements UAT-012". Drop the reference; describe what the feature does.
- **No inline PR / commit / date-of-change references in body prose.** Don't write "added in PR #97", "commit abc123 introduced …", "as of 2026-05-07 …". The git log answers those questions and stays accurate when prose drifts.

## Why

Wiki readers (maintainers, adopters) need to understand the system as it is now. References to *how it got here* are noise unless explicitly load-bearing — and even then, `wiki/log.md` and `CHANGELOG.md` are the right home, not body prose. Comments and pages explaining *what changed when* rot the moment another change lands.

## Exceptions

- **`wiki/log.md`** — append-only change ledger, exempt by design.
- **`wiki/meta/`** — audit artifacts (lint reports, consolidate reports). Their purpose is referencing specific commits / SHAs / dates, so the no-inline-refs rule does not apply.
- **Frontmatter (`created`, `updated`, `status`, etc.)** — metadata, not prose.
- **`.claude/`, `.specify/` instruction files** — UAT references there are part of the SPEC machinery, not retrospective documentation. Do not scrub them.
- **Targeted archival labels** — e.g. the `## Historical context (from <older-title>)` heading `/wiki-consolidate` writes when merging a superseded page is a deliberate label that identifies lifted content; not the prose pattern this rule bans.

## Audit

Before merging changes that touch `wiki/**` or `app/**` comments, and before running `/wiki-sync` / `/wiki-lint` / `/wiki-consolidate`:

```bash
# UAT refs in wiki body prose (excluding log.md and meta/ audit reports)
grep -rEn "UAT-[0-9]+" wiki/ --include="*.md" --exclude="log.md" --exclude-dir="meta"

# UAT refs in source comments
grep -rEn "// .*UAT-[0-9]+|/\*.*UAT-[0-9]+|\*.*UAT-[0-9]+" app/

# Historical-style phrasing in wiki body prose
grep -rEn "changed from|was changed|previously|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" wiki/ --include="*.md" --exclude="log.md" --exclude-dir="meta"
```

Any non-empty match outside this rule's prose is a candidate for rewrite.
