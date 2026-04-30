---
type: concept
status: active
created: 2026-04-20
updated: 2026-04-30
tags: [concept, claude, skills]
---

# Claude Skills

`.claude/skills/` holds project-local skills. Each has a `SKILL.md` with YAML frontmatter (`name`, `description`, optional `allowed-tools`) defining when it activates. Skills apply by context/intent (description match); rules apply by file path.

See [[modules/Claude Integration|the modules page]] for the full skills inventory inside `.claude/`.

## Project-local skills

| Skill              | Triggers on                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------------ |
| `eslint-fixes`     | ESLint failures, autofix conflicts (no-void, prefer-screen-queries, jest-dom matchers, you-dont-need-lodash) |
| `playwright-cli`   | Browser automation tasks (navigation, form fill, screenshots, data extraction)                               |
| `react-code`       | Writing/reviewing React components, hooks, event handlers, extraction decisions                              |
| `skeleton-loaders` | Building skeleton loading states; shimmer animation; preventing layout shift                                 |
| `tailwind`         | Tailwind class names, conditional classes, variants, twJoin/twMerge, theme tokens                            |
| `tdd`              | Red-green-refactor; integration tests; test-first development                                                |
| `typescript`       | Naming, exports, Zod schemas, function params, no-switch / no-enum patterns                                  |

## Rules vs. Skills — decision criteria

GAIA's `.claude/` surface places each kind of guidance in the layer that loads it most efficiently. Use this matrix when adding new guidance:

| Layer                    | Loads when…                                            | Use for                                                                            |
| ------------------------ | ------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| Hook (`.claude/hooks/`)  | Tool call matches a registered event                   | Mechanical enforcement (block / advise) on a specific tool shape — no judgment     |
| Rule (`.claude/rules/`)  | Matching `paths:` glob in scope (or always when empty) | File-path-bound conventions: project-wide style, route layout, accessibility, i18n |
| Skill (`.claude/skills/`) | `description:` matches user intent / context          | Cross-file reasoning patterns: refactor playbooks, error-fix recipes, TDD loop     |

Heuristic when migrating:

- **Rule → hook** when the guidance can be phrased as a deterministic block on a specific tool call (e.g. "no bare `pnpm test`" → `block-bare-test.sh`).
- **Rule → skill** when the guidance is a body of patterns triggered by intent rather than file path (e.g. ESLint fix recipes only matter when fixing lint, not on every edit) and benefits from references that load on demand.
- **Keep as rule** when it must auto-apply whenever a file in scope is touched, regardless of user intent (e.g. `i18n.md` for `app/pages/**`, `accessibility.md`, `coding-guidelines.md`, `quality-gate.md`).

## Skill references convention

`SKILL.md` is stack-agnostic lazy philosophy. It auto-loads into context, so it must stay short and general.

Stack-specific or deep-dive content lives in `references/{topic}.md` inside the skill directory, loaded on demand. `SKILL.md` hints at available references via markdown links. Adding support for a new stack means adding a new reference file — `SKILL.md` itself is never touched.

**Example:** `skills/tdd/SKILL.md` links to `skills/tdd/references/tests-react.md`. A new Svelte testing reference would go in `skills/tdd/references/tests-svelte.md`.

See [[Claude Integration Conventions]] for the broader convention covering extension points, monorepo retrofit, and service swaps.

## Plugin skills (claude-obsidian v1.6.0)

GAIA's wiki workflow is powered by the `claude-obsidian` plugin, installed globally via the Claude Code marketplace (not vendored into this repo). The plugin contributes ten `claude-obsidian:*` skills. They auto-load on context match alongside GAIA's project-local skills:

- `claude-obsidian:wiki` — bootstrap or check the wiki vault; routes to specialized sub-skills.
- `claude-obsidian:wiki-ingest` — read a source (file or URL), extract entities/concepts, file structured pages, update cross-references and the log.
- `claude-obsidian:wiki-query` — answer questions using the vault (hot cache → index → drill in), with citations; quick / standard / deep modes.
- `claude-obsidian:wiki-lint` — health check: orphans, dead wikilinks, stale claims, missing cross-refs, frontmatter gaps; updates Dataview dashboards.
- `claude-obsidian:save` — file the current chat or a specific insight as a structured wiki note.
- `claude-obsidian:autoresearch` — autonomous iterative research loop that searches, synthesizes, and files findings into the vault.
- `claude-obsidian:canvas` — create and edit Obsidian canvas files (images, text, PDFs, wiki pages).
- `claude-obsidian:defuddle` — strip ads/nav/boilerplate from web pages before ingesting (saves 40-60% tokens).
- `claude-obsidian:obsidian-bases` — create and edit Obsidian Bases (the native database layer for dynamic tables, filters, formulas).
- `claude-obsidian:obsidian-markdown` — write correct Obsidian Flavored Markdown (wikilinks, embeds, callouts, properties, math, canvas syntax).

The skill source lives in the upstream plugin cache (`~/.claude/plugins/cache/claude-obsidian-marketplace/claude-obsidian/<version>/skills/`), informational reference only — adopters should not edit these files. See [[Claude Integration Conventions]] § Wiki vendor relationship and [[DragonScale Opt-Out]] for the v1.6.0 baseline policy and why DragonScale's `wiki-fold` skill is dormant in our environment.
