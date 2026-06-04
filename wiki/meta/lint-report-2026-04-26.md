---
type: meta
title: 'Lint Report 2026-04-26'
created: 2026-04-26
updated: 2026-04-26
tags: [meta, lint]
status: active
---

# Wiki Lint Report: 2026-04-26

Run after the dark mode rewrite (commit `31cdf4d`, Epic Stack pattern) and the pnpm migration (commit `65c75a8`). Previous report: [[lint-report-2026-04-21]].

## Summary

- Pages scanned: 85
- Issues found: 10 (4 critical, 4 warnings, 2 suggestions)
- Auto-fixed: 0
- DragonScale: not adopted: checks 7 and 8 skipped

---

## Critical (must fix)

### C1. `wiki/modules/Sessions.md` documents removed files

- **Affected**: `wiki/modules/Sessions.md` lines 19 and 29
- **Problem**: The Dark Mode Modernization ADR (commit `31cdf4d`) explicitly removed `app/sessions.server/theme.ts` and `app/routes/actions+/set-theme.ts`. Sessions.md still documents both:
  - Line 19: table row for `theme.ts` cookie and `getThemeSession`
  - Line 29: full prose section describing `getThemeSession(request)` → `<ThemeProvider>` → `actions+/set-theme.ts` pipeline
  - Verified: `app/sessions.server/theme.ts` does not exist on disk. `app/routes/actions+/set-theme.ts` does not exist.
- **Suggested fix**: Remove the `theme.ts` row from the sessions table. Replace the "Theme cookie" section with a note that theme is now handled in `app/utils/theme.server.ts` and `app/routes/resources+/theme-switch.tsx`. Link to [[Theme Flow]] for the current pipeline.

### C2. `wiki/modules/State.md` describes a removed ThemeProvider architecture

- **Affected**: `wiki/modules/State.md`: "Bundled Providers" table (line 20) and "Theme State" section (lines 57–59)
- **Problem**: The Dark Mode Modernization removed `app/state/theme.tsx`. `app/state/index.tsx` is now a trivial passthrough (`const State: FC = ({children}) => <>{children}</>`) with no providers. State.md still documents:
  - `ThemeProvider` in the Bundled Providers table with `getThemeSession(request)` as initial state source
  - A full "Theme State" section describing `localStorage` sync, `prefers-color-scheme` media query, `useFetcher` POST to `actions/set-theme`, `ThemeHead`, `getPreferredTheme()`, `isSupportedTheme()`: all of which now live in `app/routes/resources+/theme-switch.tsx`
- **Suggested fix**: Remove the Bundled Providers table (or replace with a note that no providers are currently registered). Remove the "Theme State" section. Add a cross-reference to [[Theme Flow]] for where theme logic now lives. Update the "Canonical Pattern" and "Naming Conventions" sections to reflect the empty-state reality.

### C3. `wiki/modules/Components.md` references a removed component

- **Affected**: `wiki/modules/Components.md`: Bundled components table (line 51)
- **Problem**: The row `ThemeSwitcher | Light/dark switcher tied to actions+/set-theme` references a component and action route both deleted in the Dark Mode Modernization. Verified: `app/components/ThemeSwitcher/` does not exist; `app/routes/actions+/` contains only `set-language.ts`. The new `ThemeSwitch` component is co-located in `app/routes/resources+/theme-switch.tsx`.
- **Suggested fix**: Replace the `ThemeSwitcher` row with `ThemeSwitch` noting it lives at `app/routes/resources+/theme-switch.tsx` (co-located route + component + hooks). Link to [[Theme Flow]].

### C4. `wiki/overview.md` architecture block lists deleted page groups

- **Affected**: `wiki/overview.md` line 45 (folder tree block)
- **Problem**: The architecture tree reads `pages/ | page-specific UI (Auth, Public, Session)`. Both `app/pages/Auth/` and `app/pages/Session/` were deleted in Phase D. Only `app/pages/Public/` remains on disk. The Phase D log entry claims `[[overview]]` was "surgically cleaned" but this specific line was missed.
- **Suggested fix**: Change to `pages/ | page-specific UI (Public/)` or `pages/ | page-specific UI (Public/: add Session/ when you add auth)`.

---

## Warnings (should fix)

### W1. `wiki/hot.md` branch claim is stale

- **Affected**: `wiki/hot.md` line 25
- **Problem**: States `Branch feat/improved-migration-command`. The current git branch is `feat/dark-mode-update`. The dark mode rewrite opened a new branch that is not reflected in the hot cache.
- **Suggested fix**: Rewrite `wiki/hot.md` to reflect the current branch, the dark mode Epic Stack rewrite as last-shipped work, and any active threads. This is the cache's primary purpose.

### W2. `wiki/log.md` missing entry for the dark mode rewrite

- **Affected**: `wiki/log.md`: top (most-recent entry position)
- **Problem**: Commit `31cdf4d` (`feat: rewrite dark mode with cookie + client hints`) has no log entry. The log's most recent entry covers the pnpm migration (`65c75a8`). Per wiki convention, significant feature commits that touch code and wiki pages get a log entry.
- **Suggested fix**: Add a `[2026-04-26] feat | dark mode rewrite: cookie + client hints (Epic Stack pattern)` entry at the top summarizing: files added (`app/utils/theme.server.ts`, `app/utils/client-hints.tsx`, `app/routes/resources+/theme-switch.tsx`), files removed (`app/state/theme.tsx`, `app/sessions.server/theme.ts`, `app/routes/actions+/set-theme.ts`, `app/components/ThemeSwitcher/`), wiki pages updated, and the key insight (cookie-as-truth eliminates FOUC without an inline blocking script).

### W3. `wiki/README.md` not linked from `wiki/index.md`

- **Affected**: `wiki/README.md` (1 inbound link: from `log.md` historical text only)
- **Problem**: `wiki/README.md` is the vault schema document (mode declaration, folder structure, conventions, operations). It is not listed in `index.md`. Its only inbound link is in an append-only historical sentence in `log.md`: "CLAUDE (later renamed to [[README]])". This issue was flagged as W1 in the previous two lint reports and remains unfixed.
- **Suggested fix**: Add `[[README]]` to the `## Meta` section of `wiki/index.md` with a short description such as "vault schema, mode declaration, conventions."

### W4. `wiki/overview.md` Tech Stack State entry is stale

- **Affected**: `wiki/overview.md` line 29
- **Problem**: Tech Stack table reads `State | Plain React Context+Provider (Theme)`. After the Dark Mode Modernization, the state barrel is a no-op passthrough with no providers. Theme is no longer managed through React Context.
- **Suggested fix**: Remove the `(Theme)` parenthetical, or change the description to reflect that Context+Provider is available for consumer use but no providers are currently registered out of the box.

---

## Suggestions (worth considering)

### S1. `wiki/modules/Sessions.md` "Adding auth sessions" cross-reference gap

- **Affected**: `wiki/modules/Sessions.md` "Adding auth sessions" section
- **Problem**: After fixing C1, the "Adding auth sessions" section will correctly describe how to add auth cookies, but readers may not realize the theme cookie mechanism shifted away from `createCookieSessionStorage` to plain `cookie` package via `app/utils/theme.server.ts`. The surrounding context will be incomplete. Low priority.
- **Suggested fix**: Add a parenthetical noting that the theme cookie is now handled outside the sessions layer: see [[Theme Flow]] for the current implementation.

### S2. Unlinked mentions of `Storybook` in decision pages

- **Affected**:
  - `wiki/decisions/Thin Routes.md` line 18: "composeStory + Storybook stories" (unlinked)
  - `wiki/decisions/No Component Library.md` line 20: "MSW, Storybook" (unlinked)
  - `wiki/decisions/Co-located Tests Folder.md` line 13: "Storybook stories" (unlinked)
  - `wiki/overview.md` lines 12 and 31: "Storybook" mentioned twice without wikilink
- **Suggested fix**: Add `[[Storybook]]` or `[[Storybook Stories]]` wikilinks at these mention sites. Use `[[Storybook Stories]]` for references to the `.storybook/` module setup; use `[[Storybook]]` for the dependency. Low priority.

---

## Checks with clean results

- **Dead wikilinks**: None found outside lint reports. `[[CLAUDE]]` dead links remain only in historical lint report text and a single `log.md` append-only sentence: both intentionally untouched. Escaped-pipe links (`[[Form YearMonthDay\|YearMonthDay]]` in table cells) are valid Obsidian syntax, not broken links.
- **Stale index entries**: All 38 wikilinks in `index.md` resolve to existing files. Index is clean.
- **Orphan pages**: No true orphans (0 inbound links). Pages with only 1 inbound link (all via `index.md`): `Agentic Design`, `dashboard`, `lint-report-2026-04-21`, `lint-report-2026-04-26`. `README` has 1 inbound from `log.md` historical text: see W3 for the index gap.
- **Required frontmatter** (`type`, `status`, `created`, `updated`, `tags`): All 85 pages pass. `wiki/hot.md` wraps its YAML in an HTML comment block; the YAML itself is valid and complete.
- **Empty sections**: No genuinely empty sections. Headings that appear childless have content in immediate sub-headings (e.g. `## The four canonical patterns` in Agentic Design).
- **Stale seed pages**: None. No pages carry `status: seed`.
- **Large pages (>300 lines)**: None. Largest: `Claude Integration Conventions.md` (165), `MSW Handlers.md` (158), `Agentic Design.md` (140), `Claude Integration.md` (138).
- **Prior issues resolved**: `wiki-squash-autocommits.sh` now present in `Claude Integration.md` (was C3 in 2026-04-21 report). `tdd` skill now in Skills table (was W3 in 2026-04-21 report). Stale mode string in `Initial Ingest.md` fixed (was C2 in prior 2026-04-26 report).
- **DragonScale**: Not adopted. `scripts/allocate-address.sh` absent, `.vault-meta/address-counter.txt` absent, `scripts/tiling-check.py` absent. Checks 7 and 8 skipped per feature-detection protocol. See [[DragonScale Opt-Out]].
- **Folder naming**: All domain folders use lowercase. Convention satisfied.
- **Tag casing**: All tags lowercase across all 85 pages. Convention satisfied.
