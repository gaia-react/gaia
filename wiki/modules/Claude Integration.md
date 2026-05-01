---
type: module
path: .claude/
status: active
purpose: Claude Code integration — commands, rules, hooks, agents, skills
created: 2026-04-20
updated: 2026-05-01
tags: [module, claude, hooks]
---

# Claude Integration

GAIA ships with [Claude Code](https://claude.ai/) support out of the box. Everything in `.claude/` is checked in and shared with the team.

## Layout

`.claude/` contains `settings.json` (hooks, env, plugins), `settings.local.json` (gitignored personal overrides), `agents/`, `agent-memory/` (gitignored, ephemeral; **not** a source of truth — durable knowledge belongs in the wiki), `audit/` (gitignored hook output, e.g. `wiki-evaluator-{sha}.log`), `commands/`, `hooks/`, `rules/`, and `skills/`.

## Commands (slash)

The maintainer-only commands live under `.claude/commands/`; everything user-invokable is a skill (next section).

| Command         | What it does                                                                                                                       |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `/gaia-init`    | Rename + strip GAIA branding + configure languages + install Claude toolchain (run once on a fresh `create-gaia` scaffold)         |
| `/gaia-release` | **Maintainer-only, stripped from tarball.** Cut a GAIA release — bump, audit, scrub wiki, commit, tag, push ([[Release Workflow]]) |

## Rules

Rules activate automatically based on file paths — no need to invoke them.

| Rule                                   | Applies to                                              |
| -------------------------------------- | ------------------------------------------------------- |
| [[Coding Guidelines]]                  | All code                                                |
| `routes.md` ([[Routing]])              | `app/routes/**`, `app/pages/**`                         |
| [[API Service Pattern]]                | `app/services/**`, `test/mocks/**`                      |
| `state-pattern.md` ([[State]])         | `app/state/**`                                          |
| `storybook.md` ([[Storybook Stories]]) | `app/**/*.stories.tsx`, `.storybook/**`                 |
| `tailwind.md` ([[Tailwind]])           | `app/**/*.{tsx,css}`                                    |
| `playwright.md` ([[Playwright]])       | `.playwright/**`, `playwright.config.*`                 |
| `i18n.md` ([[i18n]])                   | `app/pages/**`, `app/components/**`, `app/languages/**` |
| [[Accessibility]]                      | `app/components/**`, `app/pages/**`                     |
| [[Git Workflow]]                       | All `git` commands (hook-enforced)                      |
| [[Quality Gate]]                       | Commits (source + gate-affecting config only)           |
| [[PR Merge Workflow]]                  | PR merges                                               |
| [[Task Orchestration]]                 | Multi-file work                                         |
| `shell-cwd.md`                         | Bash `cd` discipline (relative-path hooks)              |

## Hooks

Bash hooks wired through `.claude/settings.json`. Mixed event types.

### PreToolUse (Edit/Write/MultiEdit)

| Hook                               | Type         | Behavior                                                                                                                       |
| ---------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `block-env-write.sh`               | **Blocking** | Denies writes to `.env` / `.env.*` (allow `.env.example`). Local secrets must remain gitignored and edited by hand.            |
| `block-eslint-config-edit.sh`      | **Blocking** | Prevents modifying `eslint.config.mjs` to fix lint errors. Fix the source, not the config.                                     |
| `block-lockfile-edit.sh`           | **Blocking** | Denies direct edits to `pnpm-lock.yaml`. Run `pnpm install` / `pnpm add` / `pnpm remove` and let pnpm regenerate the lockfile. |
| `block-secrets-write.sh`           | **Blocking** | Detects AWS keys, GH PATs, PEM headers, and high-entropy secret-like values in writes; allows placeholders / templated refs.   |
| `block-vitest-globals-tsconfig.sh` | **Blocking** | Prevents adding `vitest/globals` to `tsconfig.json`. Use explicit imports.                                                     |
| `check-i18n-strings.sh`            | Advisory     | Reminds to use `t()` for user-facing strings in pages/components                                                               |
| `check-story-exists.sh`            | Advisory     | Reminds to add a Storybook story for new components                                                                            |

### PreToolUse (Bash)

Each entry uses an `if:` pattern so the hook only runs for the matching command shape.

| Hook                            | `if` pattern                     | Type         | Behavior                                                                                                                                               |
| ------------------------------- | -------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `block-bare-test.sh`            | `Bash(pnpm *)` and `Bash(npm *)` | **Blocking** | Denies bare `pnpm test` / `npm test` (watch mode). Requires `--run` for a one-shot pass.                                                               |
| `block-main-destructive-git.sh` | `Bash(git *)`                    | **Blocking** | Denies `git commit` on `main`/`master`, plain `git push` from `main`/`master` (PR-only flow), and force-push to `main`/`master`. See [[Git Workflow]]. |
| `block-rm-rf.sh`                | `Bash(rm *)`                     | **Blocking** | Denies `rm -rf` of `/`, `~`, `.git`, and other root-level / repo-critical paths.                                                                       |
| `pr-merge-audit-check.sh`       | `Bash(gh pr merge:*)`            | Advisory     | Reminds to run `code-review-audit` before merging. See [[PR Merge Workflow]].                                                                          |

### PostToolUse (Bash)

| Hook                       | `if` pattern         | Type         | Behavior                                                                                                                                                                                                                                                                                                                                                                                              |
| -------------------------- | -------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wiki-update-evaluator.sh` | `Bash(git commit:*)` | Non-blocking | After each `git commit` (skips `--amend` and `wiki:*` subjects), backgrounds `claude -p --model sonnet` to evaluate the commit diff against the wiki and apply any warranted updates. The sub-agent commits independently with `wiki: evaluator update for <sha>`. Output lands in `.claude/audit/wiki-evaluator-{sha}.log` (gitignored). The `wiki-squash-autocommits.sh` Stop hook folds the chain. |

### UserPromptSubmit

| Hook                | Behavior                                                                                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `intercept-init.sh` | Blocks the built-in `/init` and auto-invokes the `/gaia-init` skill instead. Protects the curated `CLAUDE.md` from overwrite. Removes itself (hook + settings entry) when `/gaia-init` completes. |

### SessionStart (update prompts)

| Hook                            | Event                            | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gaia-session-update-prompt.sh` | SessionStart (`startup\|resume`) | Reads `.gaia/cache/update-check.json` and emits a `<system-reminder>` asking the user whether to run the `update-deps` or `update-gaia` skill. Sequences deps before gaia (one prompt per session; falls through to gaia when deps is snoozed). Snoozes 6h after each emit. Background-fires `.gaia/scripts/check-updates.sh` (TTL 6h) when the cache is stale. Silent when the cache is missing or `jq` isn't installed. Never blocks. |

### SessionStart / Stop (wiki coherence)

Pair of hooks that compensates for a gap in the `claude-obsidian` plugin: its `PostToolUse` hook auto-commits `wiki/` changes, so by Stop time the plugin's own diff-check against HEAD is always empty and its `wiki/hot.md` refresh prompt never fires.

| Hook                         | Event        | Behavior                                                                                                                                                            |
| ---------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wiki-session-start.sh`      | SessionStart | Writes current HEAD SHA to `.git/claude-session-start` as a session marker.                                                                                         |
| `wiki-session-stop.sh`       | Stop         | If commits between the marker and HEAD touched `wiki/`, emits a `WIKI_CHANGED:` prompt and advances the marker. Silently resets on unreachable SHAs (rebase/reset). |
| `wiki-squash-autocommits.sh` | Stop         | Squashes the chain of `claude-obsidian` PostToolUse auto-commits made during the session into a single `wiki:` commit. Keeps git history clean.                     |

## Agents

### [[Code Review Audit Agent]]

Runs automatically before every PR merge (per [[PR Merge Workflow]]). Reviews:

- Security vulnerabilities (auth, injection, data exposure)
- Performance (N+1, re-renders, bundle size)
- Code smells & anti-patterns
- Architectural concerns
- Robustness & edge cases
- Maintainability

Pre-seeded with GAIA's architecture knowledge. Durable findings belong in the wiki (`wiki/concepts/Code Review Audit Agent.md` and adjacent pages). The `.claude/agent-memory/code-review-audit/` directory exists for ephemeral session state only and is gitignored — treat it as cache, not source of truth.

After its own review, it spawns 3 parallel specialist subagents to audit changed `.ts/.tsx` files against:

1. React patterns
2. TypeScript & architecture
3. Translation rules

## Skills

`.claude/skills/` holds three groups: a `/gaia` router for user-invoked workflows, scaffolders, and context-triggered guidance. See [[Claude Skills]] for the full grouped table; the entries here are the inventory.

### `/gaia` router

| Skill           | Use                                                                                                   |
| --------------- | ----------------------------------------------------------------------------------------------------- |
| `gaia`          | Routes `/gaia <subcommand>` to one of the four references below. See [[Claude Skills]] for help text. |
| → `plan` ref    | Plan a feature using [[Task Orchestration]] without implementing. See [[GAIA Plan]].                  |
| → `handoff` ref | Generate a session handoff doc. See [[GAIA Handoff]].                                                 |
| → `pickup` ref  | Resume from the latest handoff. See [[GAIA Pickup]].                                                  |
| → `audit` ref   | Two-stage knowledge-store audit (Sonnet + Sonnet). See [[GAIA Audit]].                                |

### Scaffolders

| Skill           | Use                                                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `new-component` | Scaffold a component (PascalCase folder + `index.tsx` + `tests/`) with optional Storybook story                               |
| `new-hook`      | Scaffold a custom `use*` hook + Vitest test                                                                                   |
| `new-route`     | Scaffold a route + `app/pages/{Group}/{PageName}/` + tests + i18n keys                                                        |
| `new-service`   | Scaffold an API service under `app/services/gaia/{name}/` (parsers, types, requests) + MSW collections                        |
| `update-deps`   | Autonomous Dependabot — discover outdated packages, audit `pnpm.overrides`, apply major-bump migrations, run [[Quality Gate]] |
| `update-gaia`   | Pull a later GAIA release into the project — three-way diff, drift-safe merge ([[Update Workflow]])                           |

### Context-triggered

| Skill              | Use                                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------------------- |
| `eslint-fixes`     | Resolve specific ESLint errors / autofix conflicts encountered in this project ([[ESLint Fixes]])    |
| `playwright-cli`   | Drive Playwright browser automation from Claude (e2e tests, screenshots, form filling)               |
| `react-code`       | React component/hook patterns                                                                        |
| `skeleton-loaders` | Pixel-perfect loading states                                                                         |
| `tailwind`         | Tailwind class conventions                                                                           |
| `tdd`              | Red-green-refactor TDD workflow with a `references/tests-react.md` companion ([[Component Testing]]) |
| `typescript`       | TypeScript conventions                                                                               |

The router and scaffolder skills are user-invoked (slash command or natural-language trigger). Context-triggered skills activate automatically when their `description:` matches the user's intent.

## settings.json

Registers the PreToolUse hooks on `Edit|Write|MultiEdit` and `Bash` matchers, the PostToolUse `wiki-update-evaluator.sh` on `Bash(git commit:*)`, the `intercept-init.sh` UserPromptSubmit hook, and the `SessionStart` / `Stop` wiki-coherence hooks. Enables the `typescript-lsp@claude-plugins-official` plugin.

`permissions.allow` covers routine git / gh / pnpm operations plus scoped edits for `.claude/**`, `.gaia/**`, `wiki/**`, and `CHANGELOG.md`. `permissions.deny` covers `.env` writes, `pnpm-lock.yaml` writes, `.husky/_/**` internals, force-push variants on `main`/`master`, and `git reset --hard HEAD~*`. Both lists are alphabetized; path globs are repo-relative (no leading `/`).
