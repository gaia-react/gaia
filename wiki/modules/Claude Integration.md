---
type: module
path: .claude/
status: active
purpose: Claude Code integration — commands, rules, hooks, agents, skills
created: 2026-04-20
updated: 2026-04-30
tags: [module, claude, hooks]
---

# Claude Integration

GAIA ships with [Claude Code](https://claude.ai/) support out of the box. Everything in `.claude/` is checked in and shared with the team.

## Layout

`.claude/` contains `settings.json` (hooks, env, plugins), `settings.local.json` (gitignored personal overrides), `agents/`, `agent-memory/` (gitignored, ephemeral; **not** a source of truth — durable knowledge belongs in the wiki), `audit/` (gitignored hook output, e.g. `wiki-evaluator-{sha}.log`), `commands/`, `hooks/`, `rules/`, and `skills/`.

## Commands (slash)

| Command            | What it does                                                                                                                                |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `/gaia-init`       | Rename + strip GAIA branding + configure languages + install Claude toolchain (run once)                                                    |
| `/update-gaia`     | Pull a later GAIA release into the project — three-way diff, drift-safe merge ([[Update Workflow]])                                         |
| `/gaia-release`    | **Maintainer-only, stripped from tarball.** Cut a GAIA release — bump, audit, scrub wiki, commit, tag, push ([[Release Workflow]])          |
| `/new-route`       | Scaffold a route + page + tests + i18n                                                                                                      |
| `/new-component`   | Scaffold a component with optional test + story                                                                                             |
| `/new-service`     | Scaffold an API service + Zod + URL constants + MSW mocks                                                                                   |
| `/new-hook`        | Scaffold a custom hook + test                                                                                                               |
| `/audit-code`      | Run the full [[Quality Gate]]                                                                                                               |
| `/audit-knowledge` | Audit memory + wiki + auto-loaded files for dupes, stale entries, and bloat ([[Audit-Knowledge Command]])                                   |
| `/update-deps`     | Autonomous Dependabot — discover all outdated packages, audit `pnpm.overrides`, apply codebase migrations for major bumps, run quality gate |
| `/handoff`         | Generate a session handoff doc at `.claude/handoff/HANDOFF-{date}-{slug}.md` ([[Handoff Command]])                                          |
| `/pickup`          | Resume from the latest handoff; falls back to `wiki/hot.md` ([[Pickup Command]])                                                            |

See individual rules for the patterns each command produces.

## Rules

Rules activate automatically based on file paths — no need to invoke them.

| Rule                                   | Applies to                                              |
| -------------------------------------- | ------------------------------------------------------- |
| [[Coding Guidelines]]                  | All code                                                |
| `new-route.md` ([[Routing]])           | `app/routes/**`, `app/pages/**`                         |
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

| Hook                            | `if` pattern                     | Type         | Behavior                                                                                                                                                  |
| ------------------------------- | -------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `block-bare-test.sh`            | `Bash(pnpm *)` and `Bash(npm *)` | **Blocking** | Denies bare `pnpm test` / `npm test` (watch mode). Requires `--run` for a one-shot pass.                                                                  |
| `block-main-destructive-git.sh` | `Bash(git *)`                    | **Blocking** | Denies `git commit` on `main`/`master`, plain `git push` from `main`/`master` (PR-only flow), and force-push to `main`/`master`. See [[Git Workflow]].    |
| `block-rm-rf.sh`                | `Bash(rm *)`                     | **Blocking** | Denies `rm -rf` of `/`, `~`, `.git`, and other root-level / repo-critical paths.                                                                          |
| `pr-merge-audit-check.sh`       | `Bash(gh pr merge:*)`            | Advisory     | Reminds to run `code-review-audit` before merging. See [[PR Merge Workflow]].                                                                             |

### PostToolUse (Bash)

| Hook                        | `if` pattern         | Type         | Behavior                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------- | -------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wiki-update-evaluator.sh`  | `Bash(git commit:*)` | Non-blocking | After each `git commit` (skips `--amend` and `wiki:*` subjects), backgrounds `claude -p --model sonnet` to evaluate the commit diff against the wiki and apply any warranted updates. The sub-agent commits independently with `wiki: evaluator update for <sha>`. Output lands in `.claude/audit/wiki-evaluator-{sha}.log` (gitignored). The `wiki-squash-autocommits.sh` Stop hook folds the chain. |

### UserPromptSubmit

| Hook                | Behavior                                                                                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `intercept-init.sh` | Blocks the built-in `/init` and auto-invokes the `/gaia-init` skill instead. Protects the curated `CLAUDE.md` from overwrite. Removes itself (hook + settings entry) when `/gaia-init` completes. |

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

`.claude/skills/`:

| Skill              | Use                                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------------------- |
| `eslint-fixes`     | Resolve specific ESLint errors / autofix conflicts encountered in this project ([[ESLint Fixes]])    |
| `playwright-cli`   | Drive Playwright browser automation from Claude (e2e tests, screenshots, form filling)               |
| `react-code`       | React component/hook patterns                                                                        |
| `skeleton-loaders` | Pixel-perfect loading states                                                                         |
| `tailwind`         | Tailwind class conventions                                                                           |
| `tdd`              | Red-green-refactor TDD workflow with a `references/tests-react.md` companion ([[Component Testing]]) |
| `typescript`       | TypeScript conventions                                                                               |

These activate automatically based on context.

### Statusline

GAIA ships a project-scoped statusline wrapper at `.gaia/statusline/gaia-statusline.sh`, wired by `/gaia-init`. The wrapper appends right-aligned hints (`Run /update-deps (N outdated)`, `Run /update-gaia (GAIA <ver> available)`) and delegates the left side in this priority order:

1. Sentinel file `.gaia/statusline/.use-vendored-base` (gitignored) → run the vendored renderer `.gaia/statusline/preferred-base.sh`. Project-only mode, no global install.
2. `~/.claude/settings.json` `statusLine.command` → run that. Adopter's custom statusline appears unchanged inside the GAIA project.
3. Fallback → run `.gaia/statusline/preferred-base.sh` directly.

`/gaia-init` shows a colored preview and asks adopters on Claude's default statusline whether to install the GAIA layout globally, project-only (writes the sentinel), or skip. Update checks are TTL-cached (6h) in `.gaia/cache/statusline-update-check.json`. Opt-out entirely by removing the `statusLine` key from `.claude/settings.json`.

## settings.json

Registers the PreToolUse hooks on `Edit|Write|MultiEdit` and `Bash` matchers, the PostToolUse `wiki-update-evaluator.sh` on `Bash(git commit:*)`, the `intercept-init.sh` UserPromptSubmit hook, and the `SessionStart` / `Stop` wiki-coherence hooks. Enables the `typescript-lsp@claude-plugins-official` plugin.

`permissions.allow` covers routine git / gh / pnpm operations plus scoped edits for `.claude/**`, `.gaia/**`, `wiki/**`, and `CHANGELOG.md`. `permissions.deny` covers `.env` writes, `pnpm-lock.yaml` writes, `.husky/_/**` internals, force-push variants on `main`/`master`, and `git reset --hard HEAD~*`. Both lists are alphabetized; path globs are repo-relative (no leading `/`).
