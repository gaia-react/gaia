---
type: module
path: .claude/
status: active
purpose: Claude Code integration — commands, rules, hooks, agents, skills
created: 2026-04-20
updated: 2026-05-04
tags: [module, claude, hooks]
---

# Claude Integration

GAIA ships with [Claude Code](https://claude.ai/) support out of the box. Everything in `.claude/` is checked in and shared with the team — except the `.local` / gitignored exceptions noted below.

## Layout convention

`.claude/` is split by lifecycle, not by feature:

- `settings.json` — committed; hooks, env, plugins
- `settings.local.json` — gitignored; personal overrides
- `agent-memory/` — gitignored, ephemeral; **not** a source of truth — durable knowledge belongs in the wiki
- `agents/` — sub-agent definitions
- `commands/` — maintainer-only slash commands
- `hooks/` — bash hooks invoked by `settings.json`
- `instructions/` — parameterized one-shot runbooks dispatched by commands like `/gaia-init`; self-deleting after use
- `rules/` — auto-attached guidance, file-path scoped
- `skills/` — user-invokable workflows, scaffolders, context-triggered guidance

## Commands vs. skills

Maintainer-only commands live under `.claude/commands/`. Everything user-invokable is a skill in `.claude/skills/`. The `/gaia` skill routes user-invoked workflows (plan / handoff / pickup / audit). For the current inventory, query Serena or list the folder directly.

## Rules — auto-attached

Rules activate automatically based on file paths — no need to invoke them. Each rule scopes itself to a glob in `.claude/rules/{name}.md` frontmatter. The set covers code conventions ([[Coding Guidelines]], [[State]], [[Routing]], [[i18n]], [[Tailwind]], [[API Service Pattern]], [[Storybook Stories]], [[Playwright]]), workflow ([[Git Workflow]], [[Quality Gate]], [[PR Merge Workflow]], [[Task Orchestration]]), and harness discipline (`shell-cwd.md`, `instruction-files.md`, `code-search.md`).

For the current full rule list, query Serena or list `.claude/rules/`.

## Hooks — wired through `settings.json`

Hooks are bash scripts wired through `.claude/settings.json`. The set covers four event types:

### Blocking hooks (deny risky actions)

These are the load-bearing safety net. They block the action outright and return a message:

- `block-env-write.sh` — denies writes to `.env` / `.env.*` (allows `.env.example`). Local secrets must stay gitignored.
- `block-eslint-config-edit.sh` — prevents modifying `eslint.config.mjs` to fix lint errors. Fix the source, not the config.
- `block-lockfile-edit.sh` — denies direct edits to `pnpm-lock.yaml`. Use `pnpm install` / `add` / `remove`.
- `block-secrets-write.sh` — detects AWS keys, GH PATs, PEM headers, high-entropy secret-like values; allows placeholders.
- `block-vitest-globals-tsconfig.sh` — prevents adding `vitest/globals` to `tsconfig.json`. Use explicit imports.
- `block-bare-test.sh` — denies bare `pnpm test` / `npm test` (watch mode). Requires `--run`.
- `block-main-destructive-git.sh` — denies `git commit` on `main`/`master`, plain `git push` from `main`/`master` (PR-only flow), and force-push to `main`/`master`. See [[Git Workflow]].
- `block-rm-rf.sh` — denies `rm -rf` of `/`, `~`, `.git`, and other root-level / repo-critical paths.

### Advisory hooks (nudge, don't block)

- `check-i18n-strings.sh` — reminds to use `t()` for user-facing strings in pages/components
- `check-story-exists.sh` — reminds to add a Storybook story for new components
- `pr-merge-audit-check.sh` — reminds to run `code-review-audit` before merging. See [[PR Merge Workflow]].

### Wiki coherence (a layered system)

> [!key-insight] Why three hooks for one job
> The `claude-obsidian` plugin auto-commits `wiki/` changes via its own `PostToolUse` hook, so by Stop time its diff-check against HEAD is always empty and its `wiki/hot.md` refresh prompt never fires. GAIA's `wiki-session-start.sh` + `wiki-session-stop.sh` pair fills that gap, and `wiki-squash-autocommits.sh` keeps history clean by squashing the auto-commit chain into one `wiki:` commit per session.

`wiki-update-evaluator.sh` (PostToolUse on `git commit:*`) skips `--amend` and `wiki:*` subjects, then backgrounds `claude -p --model sonnet` to evaluate the commit diff against the wiki and apply any warranted updates. Output lands in `.gaia/local/audit/` (gitignored).

### `/init` interception

`intercept-init.sh` (UserPromptSubmit) blocks the built-in `/init` and auto-invokes `/gaia-init` instead, protecting the curated `CLAUDE.md` from overwrite. It removes itself when `/gaia-init` completes.

### Statusline (no hook)

`update-deps` and `update-gaia` are surfaced via the statusline, not a hook. The wrapper at `.gaia/statusline/gaia-statusline.sh` reads `.gaia/cache/update-check.json` and right-aligns yellow `Run /update-deps (N outdated)` and/or cyan `Run /update-gaia (X.Y.Z available)` segments. Left-side rendering is delegated to the user's existing global `statusLine.command` (falling back to `Claude Code`). The hot path is cache-only; a background refresher (`.gaia/scripts/check-updates.sh`, TTL 6h) keeps the cache fresh. The `N outdated` count derives from `gaia update-deps run`, so it counts only the plan the skill will apply and inherits the `minimumReleaseAge` cooldown (see [[pnpm]]) rather than every raw `pnpm outdated` hit.

## Agents

[[Code Review Audit Agent]] runs automatically before every PR merge (per [[PR Merge Workflow]]). After its own pass over security / performance / smells / architecture / robustness / maintainability, it spawns 3 parallel specialist subagents covering React patterns, TypeScript & architecture, and translation rules.

Pre-seeded with GAIA's architecture knowledge. Durable findings belong in the wiki (`wiki/concepts/Code Review Audit Agent.md` and adjacent pages). The `.claude/agent-memory/code-review-audit/` directory is gitignored cache, not source of truth.

## Skills

`.claude/skills/` holds three groups:

- **`/gaia` router** — routes `/gaia <subcommand>` to plan / handoff / pickup / audit references
- **Scaffolders** — `new-component`, `new-hook`, `new-route`, `new-service`, `update-deps`, `update-gaia`
- **Context-triggered** — `eslint-fixes`, `playwright-cli`, `react-code`, `skeleton-loaders`, `tailwind`, `tdd`, `typescript`

The router and scaffolder skills are user-invoked. Context-triggered skills activate automatically when their `description:` matches the user's intent. See [[Claude Skills]] for the full grouped table; for the current file inventory, query Serena.

## settings.json

Registers PreToolUse hooks on `Edit|Write|MultiEdit` and `Bash` matchers, the PostToolUse `wiki-update-evaluator.sh` on `Bash(git commit:*)`, the `intercept-init.sh` UserPromptSubmit hook, and the `SessionStart` / `Stop` wiki-coherence hooks. Enables the `typescript-lsp@claude-plugins-official` plugin and Serena MCP (see [[Serena Integration]]).

`permissions.allow` covers routine git / gh / pnpm operations plus scoped edits for `.claude/**`, `.gaia/**`, `wiki/**`, and `CHANGELOG.md`. `permissions.deny` covers `.env` writes, `pnpm-lock.yaml` writes, `.husky/_/**` internals, force-push variants on `main`/`master`, and `git reset --hard HEAD~*`. Both lists are alphabetized; path globs are repo-relative (no leading `/`).

For the current verbatim contents of `settings.json`, read it directly via Serena.
