---
type: module
path: .claude/
status: active
purpose: Claude Code integration, commands, rules, hooks, agents, skills
created: 2026-04-20
updated: 2026-07-03
tags: [module, claude, hooks]
---

# Claude Integration

GAIA ships with [Claude Code](https://claude.ai/) support out of the box. Everything in `.claude/` is checked in and shared with the team, except the `.local` / gitignored exceptions noted below.

## Layout convention

`.claude/` is split by lifecycle, not by feature:

- `settings.json`: committed; hooks, env, plugins
- `settings.local.json`: gitignored; personal overrides
- `agent-memory/`: gitignored scratch path created on demand by named agents; **not** a source of truth; durable knowledge belongs in the wiki
- `agents/`: sub-agent definitions
- `commands/`: maintainer-only slash commands
- `hooks/`: bash hooks invoked by `settings.json`
- `instructions/`: parameterized one-shot runbooks dispatched by commands like `/gaia-init`; self-deleting after use
- `rules/`: auto-attached guidance, file-path scoped
- `skills/`: user-invokable workflows, scaffolders, context-triggered guidance

## Commands vs. skills

GAIA workflows are split between slash commands under `.claude/commands/` (`/gaia-plan`, `/gaia-spec`, `/gaia-audit`, `/gaia-fitness`, `/gaia-forensics`, `/gaia-harden`, `/gaia-init`, `/gaia-release`, and more) and standalone skills under `.claude/skills/` (`gaia-handoff`, `gaia-pickup`, `gaia-wiki`, each with its own `SKILL.md`). There is no `/gaia` router; each command and skill reads a shared reference file in `.claude/skills/gaia/references/`. For the current inventory, query Serena or list the folder directly.

## Rules: auto-attached

Rules activate automatically based on file paths; no need to invoke them. Each rule scopes itself to a glob in `.claude/rules/{name}.md` frontmatter. The set covers code conventions ([[Coding Guidelines]], [[State]], [[Routing]], [[i18n]], [[Tailwind]], [[API Service Pattern]], [[Storybook Stories]], [[Playwright]]), workflow ([[Git Workflow]], [[Quality Gate]], [[PR Merge Workflow]], [[Task Orchestration]]), and harness discipline (`shell-cwd.md`, `instruction-files.md`, `code-search.md`, `repo-relative-paths.md`).

For the current full rule list, query Serena or list `.claude/rules/`.

## Hooks: wired through `settings.json`

Hooks are bash scripts wired through `.claude/settings.json`. The set covers four event types:

### Blocking hooks (deny risky actions)

These are the load-bearing safety net. They block the action outright and return a message:

- `block-env-write.sh`: denies writes to `.env` / `.env.*` (allows `.env.example`). Local secrets must stay gitignored.
- `block-env-read.sh`: denies Read-tool and Bash reads of `.env.<env>` variants (`.env.local`, `.env.production`) that the literal `Read(.env)` deny misses, plus residual Bash read paths (sourcing, redirection, readers outside cat/head/tail/sed) and bare `env`/`printenv` dumps; allows `.env.example`. Heuristic defense-in-depth, not a sandbox. Registered on the `Read` and `Bash` matchers.
- `block-eslint-config-edit.sh`: prevents modifying `eslint.config.mjs` to fix lint errors. Fix the source, not the config.
- `block-lockfile-edit.sh`: denies direct edits to `pnpm-lock.yaml`. Use `pnpm install` / `add` / `remove`.
- `block-secrets-write.sh`: detects AWS keys, GH PATs, PEM headers, high-entropy secret-like values; allows placeholders.
- `block-vitest-globals-tsconfig.sh`: prevents adding `vitest/globals` to `tsconfig.json`. Use explicit imports.
- `block-bare-test.sh`: denies bare `pnpm test` / `npm test` (watch mode). Requires `--run`.
- `block-main-destructive-git.sh`: denies `git commit` on `main`/`master`, plain `git push` from `main`/`master` (PR-only flow), and force-push to `main`/`master`. See [[Git Workflow]].
- `block-no-verify.sh`: denies `git commit` / `git push` carrying a hook-bypass token (`--no-verify`, falsy `HUSKY=` prefix, `core.hooksPath` redirect) and `git commit -n`, so the commit-time deterministic floor cannot be silently skipped; `git push -n` (dry-run) stays allowed.
- `block-rm-rf.sh`: denies `rm -rf` of `/`, `~`, `.git`, and other root-level / repo-critical paths.
- `red-verify-commit-check.sh`: denies `git commit` when a new-at-HEAD test that now passes has no recorded failing (RED) run matching its current content. The sibling `capture-red-observations.sh` (PostToolUse) records REDs at test-run time; this enforces them at commit, the mechanical-TDD RED-before-GREEN gate.
- `worthiness-presence-check.sh`: denies `gh pr merge` when an emergent test the PR changed has no worthiness-ledger line matching its current content (see the worthiness-evaluator agent below).
- `serena-code-search-guard.sh`: denies a bare-identifier symbol search scoped to `app/**`/`test/**` TS/TSX, whether it arrives through the `Grep` tool or as a single `grep`/`rg`/`ag` through `Bash`, routing it to Serena's symbol tools instead; re-running the identical search passes. No-ops without a registered Serena MCP server and a `tsconfig.json`. See [[Serena Integration]].

### Advisory hooks (nudge, don't block)

- `check-i18n-strings.sh`: reminds to use `t()` for user-facing strings in pages/components
- `check-story-exists.sh`: reminds to add a Storybook story for new components
- `pr-merge-audit-check.sh`: reminds to run `code-review-audit` before merging. See [[PR Merge Workflow]].

### Wiki coherence (a layered system)

> [!key-insight] Why three hooks for one job
> The `claude-obsidian` plugin auto-commits `wiki/` changes via its own `PostToolUse` hook, so by Stop time its diff-check against HEAD is always empty and its `wiki/hot.md` refresh prompt never fires. GAIA's `wiki-session-start.sh` + `wiki-session-stop.sh` pair fills that gap, and `wiki-squash-autocommits.sh` keeps history clean by squashing the auto-commit chain into one `wiki:` commit per session.

The sync design is convergent: hooks never spawn `claude -p` sub-processes. `wiki-commit-nudge.sh` (PostToolUse, `Bash`) fires after a `git commit` and injects a `[wiki nudge]` line (short SHA, subject, file count, drift count), skipping merge / amend / `wiki:` subjects. The user's session reconciles the wiki via `/gaia-wiki sync`.

### Statusline (no hook)

`update-deps` and `update-gaia` are surfaced via the statusline, not a hook. The wrapper at `.gaia/statusline/gaia-statusline.sh` reads `.gaia/local/cache/shared/update-check.json` and right-aligns yellow `Run /update-deps (N outdated)` and/or cyan `Run /update-gaia (X.Y.Z available)` segments. Left-side rendering is delegated to the user's existing global `statusLine.command` (falling back to `Claude Code`). The hot path is cache-only; a background refresher (`.gaia/scripts/check-updates.sh`, TTL 6h) keeps the cache fresh. The `N outdated` count derives from `gaia update-deps run`, so it counts only the plan the skill will apply and inherits the `minimumReleaseAge` cooldown (see [[pnpm]]) rather than every raw `pnpm outdated` hit. The count reads the payload's `actionable_count`, which subtracts groups the operator snoozed in the `/update-deps` preview: each run groups the outstanding updates by patch / minor / major / non-semver and lets the operator skip specific companion groups. A skipped group lands in a gitignored local ledger (`.gaia/local/declined-updates.json`) and drops out of the count until a newer version ships or 14 days pass; the preview still offers it every run. The ledger is local-statusline only; CI never reads it, so the CI update-deps cron stays the freshness backstop and keeps opening PRs.

<!-- gaia:maintainer-only:start -->
On the maintainer's own machine, a gitignored `.claude/settings.local.json` (higher precedence than the committed `settings.json`) points the `statusLine` command at a gitignored `.gaia/local/maintainer-statusline.sh` wrapper. That wrapper un-suppresses the gaia-init right-side gate, then execs the shipped `.gaia/statusline/gaia-statusline.sh`, which delegates the left segment to the global `~/.claude/statusline-wrapper.sh` → `~/.claude/statusline-command.sh`. When debugging the statusline in this repo, read `settings.local.json` first, not `settings.json`.

Because `.gaia/local/` is gitignored, `maintainer-statusline.sh` never exists in a linked worktree; the wrapper self-locates the main checkout via `git rev-parse --git-common-dir` rather than a relative path, so the statusline still resolves there. Worktree detection keys off the session cwd carried in the status payload, not the script's own install path, so right-side indicators stay scoped to whichever worktree is actually active. The left-side project name shows the main repo folder, not the worktree folder, via the global `~/.claude/statusline-command.sh`. `EnterWorktree` does not survive `claude --resume`: a resumed session returns to main, and a statusline command loaded at session start is not hot-reloaded on `EnterWorktree`.
<!-- gaia:maintainer-only:end -->

## Agents

[[Code Review Audit Agent]] runs automatically before every PR merge (per [[PR Merge Workflow]]). After its own pass over security / performance / smells / architecture / robustness / maintainability, it dispatches up to three file-scope-gated specialist subagents (React patterns when `.tsx` files changed, TypeScript & architecture when `.ts`/`.tsx` changed, translation when `t(` / `useTranslation` is present) in parallel from a single tool call, alongside the deterministic oracles `react-doctor`, `pnpm knip`, and `pnpm audit`. A subagent with no matching files is skipped.

Pre-seeded with GAIA's architecture knowledge. Durable findings belong in the wiki (`wiki/concepts/Code Review Audit Agent.md` and adjacent pages). The `.claude/agent-memory/` path is a gitignored scratch path (created on demand under a per-agent subdir such as `code-review-audit/`), not a source of truth.

`worthiness-evaluator` is an opus advisory agent that judges each emergent-surface test (under `app/components/**`, `.playwright/**`) on honesty and worthiness, returning a keep / fix / delete verdict per test. It proposes only and edits no files; every delete is human-gated. Its verdicts feed the worthiness ledger that `worthiness-presence-check.sh` enforces at merge.

## Skills

`.claude/skills/` holds these groups:

- **Standalone GAIA workflows**: `gaia-handoff`, `gaia-pickup`, `gaia-wiki`
- **Scaffolders**: `new-component`, `new-hook`, `new-route`, `new-service`, `update-deps`, `update-gaia`
- **Context-triggered**: `a11y-fixes`, `eslint-fixes`, `playwright-cli`, `react-code`, `skeleton-loaders`, `tailwind`, `tdd`, `typescript`
- **Maintainer-only**: `release-notes`

The workflow and scaffolder skills are user-invoked. Context-triggered skills activate automatically when their `description:` matches the user's intent (`a11y-fixes` resolves axe-core accessibility violations from Vitest / Playwright / the code-review-audit a11y bucket). See [[Claude Skills]] for the full grouped table; for the current file inventory, query Serena.

## settings.json

Registers PreToolUse hooks on `Edit|Write|MultiEdit`, `Bash`, `Grep`, and `Read` matchers; PostToolUse hooks on `Bash` (`wiki-commit-nudge.sh`, `capture-red-observations.sh`); UserPromptSubmit, PostCompact (`wiki-recompact-sentinel.sh`), SessionStart / Stop wiki-coherence hooks, and paired WorktreeCreate / WorktreeRemove hooks (`.gaia/scripts/create-worktree.sh`, `.gaia/scripts/remove-worktree.sh`) that own worktree creation and teardown, replacing the harness's native git-worktree logic. Sets `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` and a `statusLine` command, and enables the `typescript-lsp@claude-plugins-official` plugin. Serena MCP is registered user-globally with the `claude-code` context and `--project-from-cwd` auto-activation (`claude mcp add serena -s user`), not in this file (see [[Serena Integration]]).

`permissions.allow` covers routine git / gh / pnpm operations plus scoped edits for `.claude/**`, `.gaia/**`, `wiki/**`, and `CHANGELOG.md`. `permissions.deny` covers `.env` reads, edits, and writes (`Read(.env)`, `Edit(.env)`, `Write(.env)`), `pnpm-lock.yaml` writes, `.husky/_/**` internals, force-push variants on `main`/`master`, and `git reset --hard HEAD~*`. `Read(.env)` already enforces against the Read tool and the Bash readers Claude Code recognizes (`cat`, `head`, `tail`, `sed`) at any depth; `block-env-read.sh` delivers the residual coverage that literal match misses, the `.env.<env>` variant family and the Bash read paths outside that recognized set, as heuristic defense-in-depth, not a sandbox. The OS-level sandbox (`sandbox.filesystem` deny-read, merged with the Read/Edit deny rules) is the airtight opt-in for adopters who want enforcement that reaches arbitrary subprocesses; GAIA does not enable it by default. Both permission lists are alphabetized; path globs are repo-relative (no leading `/`).

For the current verbatim contents of `settings.json`, read it directly via Serena.
