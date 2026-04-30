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

GAIA's skills split into three groups: a `/gaia` router for user-invoked workflows, scaffolders for new code surfaces, and context-triggered guidance loaded by intent.

### `/gaia` router

| Skill                        | Triggers on                                                                            |
| ---------------------------- | -------------------------------------------------------------------------------------- |
| `gaia` (router)              | `/gaia <subcommand>` or natural-language asks; dispatches to one of the four refs below |
| → `references/plan.md`       | Plan a feature using [[Task Orchestration]]. See [[GAIA Plan]].                        |
| → `references/handoff.md`    | Write a session handoff doc. See [[GAIA Handoff]].                                     |
| → `references/pickup.md`     | Resume from the most recent handoff. See [[GAIA Pickup]].                              |
| → `references/audit.md`      | Two-stage knowledge-store audit (Sonnet + Sonnet). See [[GAIA Audit]].                 |

### Scaffolders

| Skill           | Triggers on                                                                                  |
| --------------- | -------------------------------------------------------------------------------------------- |
| `new-component` | "create a component", "scaffold a card" — drops a PascalCase folder under `app/components/` with `index.tsx` and a `tests/` dir |
| `new-hook`      | "create a useFoo hook", "add a hook under app/hooks" — drops a `useThing.ts` + Vitest test  |
| `new-route`     | "add a new page", "scaffold /dashboard" — wires a route file + `app/pages/{Group}/{PageName}/` + i18n keys |
| `new-service`   | "add a service", "scaffold the projects API" — drops `app/services/gaia/{name}/` (parsers, types, requests) and matching MSW collections |
| `update-deps`   | Autonomous Dependabot — fired by `/gaia-init`, accepted from the SessionStart update prompt, statusline nudge, or "update dependencies" |
| `update-gaia`   | Pull a later GAIA release into the project — accepted from the SessionStart update prompt, statusline nudge, or "pull the latest GAIA" |

### Context-triggered

| Skill              | Triggers on                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------------ |
| `eslint-fixes`     | ESLint failures, autofix conflicts (no-void, prefer-screen-queries, jest-dom matchers, you-dont-need-lodash) |
| `playwright-cli`   | Browser automation tasks (navigation, form fill, screenshots, data extraction)                               |
| `react-code`       | Writing/reviewing React components, hooks, event handlers, extraction decisions                              |
| `skeleton-loaders` | Building skeleton loading states; shimmer animation; preventing layout shift                                 |
| `tailwind`         | Tailwind class names, conditional classes, variants, twJoin/twMerge, theme tokens                            |
| `tdd`              | Red-green-refactor; integration tests; test-first development                                                |
| `typescript`       | Naming, exports, Zod schemas, function params, no-switch / no-enum patterns                                  |

### SessionStart update prompt

`update-deps` and `update-gaia` are also surfaced by `.claude/hooks/gaia-session-update-prompt.sh` (registered on `SessionStart: startup|resume`). The hook reads `.gaia/cache/statusline-update-check.json` (the same cache the statusline uses, TTL 6h) and emits a `<system-reminder>` asking the user whether to run the relevant skill when outdated dependencies or a newer GAIA release are available. Silent on missing cache, never blocks. See [[Claude Hooks]].

## Rules vs. Skills — decision criteria

GAIA's `.claude/` surface places each kind of guidance in the layer that loads it most efficiently. Use this matrix when adding new guidance:

| Layer                     | Loads when…                                            | Use for                                                                            |
| ------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| Hook (`.claude/hooks/`)   | Tool call matches a registered event                   | Mechanical enforcement (block / advise) on a specific tool shape — no judgment     |
| Rule (`.claude/rules/`)   | Matching `paths:` glob in scope (or always when empty) | File-path-bound conventions: project-wide style, route layout, accessibility, i18n |
| Skill (`.claude/skills/`) | `description:` matches user intent / context           | Cross-file reasoning patterns: refactor playbooks, error-fix recipes, TDD loop     |

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
