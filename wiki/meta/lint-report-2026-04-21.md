---
type: meta
status: active
created: 2026-04-21
updated: 2026-04-21
tags: [meta, lint]
---

# Wiki Lint Report: 2026-04-21

## Summary

- Pages scanned: 77
- Issues found: 9 (3 critical, 3 warnings, 3 suggestions)

---

## Critical (must fix)

### C1. Dead link: `CLAUDE` in `wiki/index.md`

- **Affected**: `wiki/index.md` line 21
- **Problem**: `wiki/CLAUDE.md` was renamed to `wiki/README.md` (commit `19f25d6`). The index still has `- `CLAUDE`: vault schema and conventions`, which resolves to nothing.
- **Fix**: Change `CLAUDE` to `[[README]]` (or remove the entry if README is intentionally excluded from the catalog).

### C2. Dead link: `CLAUDE` in `wiki/log.md`

- **Affected**: `wiki/log.md` line 104 (Initial Ingest entry)
- **Problem**: Same rename as C1. `log.md` is append-only, so this is historical, but the wikilink still resolves to a missing file.
- **Fix**: Replace `CLAUDE` with plain text `CLAUDE` (annotated as renamed) since the log is append-only history. Or redirect to `[[README]]`.

### C3. `wiki/modules/Claude Integration.md` does not document `wiki-squash-autocommits.sh`

- **Affected**: `wiki/modules/Claude Integration.md`: SessionStart/Stop hooks section
- **Problem**: `wiki/concepts/Claude Hooks.md` line 44 lists `wiki-squash-autocommits.sh` as a Stop hook alongside `wiki-session-stop.sh`. The hook file exists (`.claude/hooks/wiki-squash-autocommits.sh`) and is registered in `.claude/settings.json`. But `modules/Claude Integration.md` lists only `wiki-session-start.sh` and `wiki-session-stop.sh` in the SessionStart/Stop table: `wiki-squash-autocommits.sh` is missing.
- **Fix**: Add `wiki-squash-autocommits.sh` to the Stop hooks row in `modules/Claude Integration.md`.

---

## Warnings (should fix)

### W1. Orphan: `wiki/README.md` has zero inbound wikilinks

- **Affected**: `wiki/README.md`
- **Problem**: After the rename from `CLAUDE.md` to `README.md`, no wiki page links to `[[README]]`. The index still points to `CLAUDE` (C1 above), so `README.md` is a graph orphan.
- **Fix**: Fix C1 first (update `CLAUDE` to `[[README]]` in `index.md`). That alone resolves the orphan.

### W2. Naming convention violations: filename case

- **Affected**: The following files use non-Title-Case names contrary to the "filenames: Title Case with spaces" convention:
  - `concepts/audit-knowledge command.md`: should be `Audit-Knowledge Command.md` or `audit-knowledge Command.md`
  - `concepts/handoff command.md`: should be `Handoff Command.md`
  - `concepts/pickup command.md`: should be `Pickup Command.md`
  - `concepts/test-runner.md`: should be `Test Runner.md`
  - `decisions/composeStory Pattern.md`: mixed case, debatable; `ComposeStory Pattern.md` would be fully Title Case
  - `modules/i18n.md`: all-lowercase; `I18n.md` or `i18n.md` by convention (intentional lowercase for the abbreviation)
  - `dependencies/i18next.md`: same as above
  - `dependencies/remix-flat-routes.md`: kebab-case package name; `Remix Flat Routes.md` would match Title Case
  - `dependencies/remix-i18next.md`: same; `Remix I18next.md`
  - `dependencies/remix-toast.md`: same; `Remix Toast.md`
- **Note**: `i18n.md`, `i18next.md`, `remix-*` names are arguably intentional (matching package name case). The command pages (`handoff command.md` etc.) are clearest violations.
- **Fix**: Rename command/concept pages to Title Case. Evaluate dependency pages individually: package-name filenames may be an intentional convention.

### W3. `wiki/modules/Claude Integration.md` Skills table is stale

- **Affected**: `wiki/modules/Claude Integration.md`: Skills section (lines 120–130)
- **Problem**: The Skills table lists 4 skills (`react-code`, `typescript`, `tailwind`, `skeleton-loaders`) and notes "These activate automatically based on context." However, `wiki/concepts/Claude Integration Conventions.md` §3 documents a `tdd` skill with a `references/` convention (tests-react.md reference file). The `tdd` skill is not in the Skills table.
- **Fix**: Add `tdd` skill row to the Skills table in `modules/Claude Integration.md`.

---

## Suggestions (worth considering)

### S1. `wiki/modules/Claude Integration.md` Initial Ingest count is stale

- **Affected**: `wiki/sources/Initial Ingest.md` line 41
- **Problem**: "8 commands, 10 rules, 4 hooks, 1 review agent + 3 specialists, 4 skills" is the count from the initial ingest. Since then: hooks governance added 4 PreToolUse Bash hooks + SessionStart/Stop pair (total now 12 hooks); `tdd` skill added (total 5 skills); several commands added. The count is stale.
- **Fix**: Low priority: `Initial Ingest` is a historical source document. Either update the count or annotate "as of ingest date."

### S2. Unlinked mentions of "Playwright" in non-linking pages

- **Affected**:
  - `wiki/overview.md` line 84: comparison table cell "Playwright" unlinked
  - `wiki/decisions/TypeScript Language Files.md` line 21: "Playwright assertions" unlinked
  - `wiki/sources/Initial Ingest.md` line 36: "Playwright" unlinked in big-ideas list
- **Fix**: Add `[[Playwright]]` wikilinks at these three mention sites.

### S3. `wiki/concepts/Claude Hooks.md`: `claude-obsidian` plugin mentioned without a page or link

- **Affected**: `wiki/modules/Claude Integration.md` line ~134 and `wiki/concepts/Claude Hooks.md` (SessionStart/Stop section)
- **Problem**: The `claude-obsidian` plugin is described functionally but has no wiki page and is never linked. It is a meaningful dependency for the wiki coherence hook pair.
- **Fix**: Either add a `wiki/dependencies/claude-obsidian.md` stub, or add a brief inline description and link to its GitHub/npm in the Claude Integration or Claude Hooks page. Low priority.

---

## Checks with clean results

- **Dead links (wikilinks)**: All wikilinks resolve to existing files except C1/C2 (`CLAUDE`). Path-style links (`[[modules/Claude Integration|the modules page]]`) resolve correctly to `modules/Claude Integration.md`.
- **Required frontmatter**: All 77 pages have `type`, `status`, `created`, `updated`, and `tags`. `README.md` has all five fields (no `title:` field, but `title:` is not required per the schema in `README.md` itself).
- **Empty sections**: No headings found with zero content underneath.
- **Stale seed pages**: No pages with `status: seed`.
- **Pages over 300 lines**: None. Largest pages: `modules/MSW Handlers.md` (157 lines), `concepts/Claude Integration Conventions.md` (154 lines), `modules/Claude Integration.md` (134 lines).
- **Folder naming**: All domain folders use lowercase (`components/`, `concepts/`, `decisions/`, `dependencies/`, `entities/`, `flows/`, `meta/`, `modules/`, `sources/`). Convention satisfied.
- **Tag casing**: All tags are lowercase across all pages. Convention satisfied.
- **Stale index entries**: `index.md` has no entries pointing to deleted pages. Auth Flow, remix-auth, VitePress, and things Service were previously cleaned from the index. Only `CLAUDE` (C1) points to a renamed file.
- **Orphan pages** (excluding README: see W1): All other 76 pages have at least one inbound wikilink. Pages confirmed with 1–2 inbound links (borderline but acceptable): `log.md` (1), `Initial Ingest` (2), `lint-report-2026-04-21` (2), `FontAwesome` (3), `Utils` (3), `Steven Sacks` (3), `Accessibility` (4).
- **Stale claims**: No factual contradictions found between pages beyond the hook inventory gap (C3) and skill count (W3).
