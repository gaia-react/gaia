---
paths:
  - 'wiki/**/*.md'
  - 'frontend/app/**/*.{ts,tsx,js,jsx,css}'
  - '.claude/instructions/**/*.md'
  - 'frontend/.claude/**/*.md'
  - '.claude/skills/**/*.md'
  - '.claude/commands/**/*.md'
  - '.claude/agents/**/*.md'
  - '.claude/rules/**/*.md'
  - '.claude/doctrine/**/*.md'
  - '.claude/hooks/**/*.sh'
  - '.gaia/scripts/spec/**/*.sh'
---

# Wiki & Comment Prose Style

Body prose, and the prose a code comment carries, describes **what is** in present tense. The historical record lives in git (`git log`, `git blame`), `wiki/log.md`, and `CHANGELOG.md`, body prose is not the place for it.

## Rules

- **Present tense only.** Do not write "was changed from X to Y", "previously did A, now does B", "moved from a to b". State the current behavior directly.
- **No working-document ids.** SPEC, UAT, plan, and directive ids, issue or pull request references, and paths to machine-local artifacts under `.gaia/local/`: `.claude/rules/working-doc-ids.md` owns what is banned and what is exempt.
- **No inline PR / commit / date-of-change references in body prose.** Don't write "added in PR #97", "commit abc123 introduced …", "as of 2026-05-07 …". The git log answers those questions and stays accurate when prose drifts. Issue and pull request numbers are covered by `.claude/rules/working-doc-ids.md` everywhere this rule applies.
- **No conventions and no enumerations on a descriptive page, only a pointer to what owns them.** A page describing how something works does not restate the naming rule, the file list, the matcher set, the roster, the glob list, or the version. Name the rule file, the config file, or the command that holds it, and stop. Corollary, which is where the reflex goes wrong: when an enumeration is found stale, **delete it and point**, do not complete it. A corrected list restarts the same decay from a fresher number, and the enumeration that was wrong twice is the one most likely to be wrong again.
- **No unreleased or speculative roadmap as current behavior.** Body prose describes what ships today. Do not document a planned, deferred, or not-yet-built feature as if it already exists, a reader cannot tell aspiration from shipped fact. State current behavior; keep forward-looking notes out of the page, or label them plainly as deferred and not yet built.
  <!-- gaia:maintainer-only:start -->
  GAIA maintainers: two kinds of content go inside the HTML-comment maintainer-only markers, the same pair wrapping this note. First, roadmap or forward-looking content that must live in the source repo but not reach adopter scaffolds. Second, any statement specific to the maintainer repo itself, how `gaia-react/gaia` is configured or operated (its branch-protection / ruleset setup, per-author audit mode, secrets, in-tree-only workflows): on an adopter clone that reads as a claim about the reader's own repo and is false there, so wrap it. Keep the general behavior in the visible body and confine the maintainer-repo specifics to the wrapped block. The bundle-time scrub strips marker-delimited blocks from markdown under `wiki/` and `.claude/` before tar, so the source repo stays a superset of the adopter bundle; unbalanced markers fail the release build. See [[Bundle-time Scrub]].
  <!-- gaia:maintainer-only:end -->

## Why

Wiki readers (maintainers, adopters) need to understand the system as it is now. References to _how it got here_ are noise unless explicitly load-bearing, and even then, `wiki/log.md` and `CHANGELOG.md` are the right home, not body prose. Comments and pages explaining _what changed when_ rot the moment another change lands.

## Exceptions

- **`wiki/log.md`**: append-only change ledger, exempt by design.
- **`wiki/hot.md`**: auto-loaded recent-context cache. Body is by design a recap of recent commits / threads; historical phrasing is the point. The cache is overwritten by `/gaia-wiki sync`, not edited by hand.
- **`wiki/meta/`**: audit artifacts (lint reports, consolidate reports). Their purpose is referencing specific commits / SHAs / dates, so the no-inline-refs rule does not apply.
- **Frontmatter (`created`, `updated`, `status`, etc.)**: metadata, not prose.
<!-- gaia:maintainer-only:start -->
- **`.gaia/tests/` is out of scope entirely.** It is release-excluded maintainer-only test infrastructure that never reaches an adopter, so a UAT/SPEC reference there is never shipped-surface drift. Its suites use `UAT-NNN` / `SEC-N` / `TST-NN` test-name prefixes, header comments, and section headers as deliberate SPEC-conformance traceability; those stay. Both audit greps below omit `.gaia/tests/` for this reason, matching the release boundary. Do not re-add `.gaia/tests/` to either grep.
<!-- gaia:maintainer-only:end -->
- **Targeted archival labels**: e.g. the `## Historical context (from <older-title>)` heading `/gaia-wiki consolidate` writes when merging a superseded page is a deliberate label that identifies lifted content; not the prose pattern this rule bans.

## Audit

Before merging changes that touch any in-scope path, and before running `/gaia-wiki` (any sub-command):

```bash
# UAT / SPEC refs in wiki body prose (excluding log.md, hot.md, and meta/ audit reports)
grep -rEn "UAT-[0-9]+|SPEC-[0-9]+" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"

# UAT / SPEC refs in source comments
grep -rEn "// .*(UAT|SPEC)-[0-9]+|/\*.*(UAT|SPEC)-[0-9]+|\*.*(UAT|SPEC)-[0-9]+" frontend/app/

# UAT-NNN narrative refs in instruction files and spec-lifecycle scripts
# (functional fixture values are kept; the maintainer triages each match per
# the structural-vs-narrative distinction in `.claude/rules/working-doc-ids.md`)
grep -rEn "UAT-[0-9]{3}" \
  .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ frontend/.claude/ \
  .gaia/scripts/spec/

# Concrete maintainer SPEC IDs in instruction files and spec-lifecycle scripts
grep -rEn "\bSPEC-[0-9]{3,}\b" \
  .claude/skills/ .claude/commands/ .claude/agents/ .claude/rules/ .claude/hooks/ frontend/.claude/ \
  .gaia/scripts/spec/

# Historical-style phrasing in wiki body prose
grep -rEn "\bchanged from|was changed|previously (did|was|stated|had|used)|previously set|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta"
```

Any non-empty match outside this rule's prose is a candidate for rewrite. The narrative-vs-structural triage for the `.claude/` / `.gaia/scripts/spec/` greps is a human read, the regex flags candidates; `.claude/rules/working-doc-ids.md` codifies what stays.
