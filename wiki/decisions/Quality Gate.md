---
type: decision
status: active
priority: 1
date: 2026-04-20
created: 2026-04-20
updated: 2026-10-09
tags: [decision, ci, quality]
---

# Decision: Mandatory Quality Gate

Every change must pass the Quality Gate. Pre-commit hooks enforce a subset; Claude runs the full pipeline below before any `git commit` that touches source; **unless the gate has nothing to check**.

## Steps

The contract lives at the repo root and the commands run per package. Steps 3 to 8 are the executable steps; each root `pnpm <script>` is a proxy that forwards to the `pnpm -C frontend <script>` shown beside it, and either spelling runs the same command.

1. **Simplify**: run `simplify` skill; apply all endorsed changes.
2. **Localization check**: no hardcoded user-facing strings or unfilled keys.
3. `pnpm typecheck` (`pnpm -C frontend typecheck`): zero errors. This is the sole enforcer for type-only tests (`expectTypeOf`/`assertType`/`@ts-expect-error`), which [[TDD RED Verification]] exempts from its runtime-RED demand.
4. `pnpm lint` (`pnpm -C frontend lint`): zero errors, zero warnings. Runs `eslint --fix`, so it auto-fixes every fixable lint rule **and** Prettier formatting (Prettier is wired in as an `eslint` rule via `prettier/prettier`); only non-auto-fixable issues need manual attention. Hand-formatting while authoring is wasted effort; this step normalizes it. `pnpm lint` ignores `.gaia/**`.
   <!-- gaia:maintainer-only:start -->
   Changes touching `.gaia/cli/**` also run `pnpm lint:cli` (`pnpm -C .gaia/cli lint`), the CLI's own ESLint config (the CLI is a root workspace member), and `pnpm -C .gaia/cli typecheck`: the root `pnpm typecheck` covers only the frontend package, and the CLI's ESLint and vitest runs do not type-check.
   <!-- gaia:maintainer-only:end -->
5. `pnpm test --run` (`pnpm -C frontend test --run`): all tests pass with **zero console warnings** (missing keys, HydrateFallback, etc. count as failures). Stories and hook tests run in headless Chromium, so `pnpm install:browsers` must have run once; a missing browser fails the step with an install command ([[Stories as Tests]]).
6. `pnpm pw` (`pnpm -C frontend pw`): all Playwright E2E tests pass. Playwright reads the `.env` of its working directory, so the file is `frontend/.env`; without it the web server never starts. Entering a worktree provisions it, which symlinks the main checkout's `frontend/.env` into the worktree's `frontend/`, so a worktree missing one was never entered by a session: run `bash .claude/hooks/provision-worktree.sh <absolute-worktree-path>`, which also installs dependencies and moves a plain `.gaia/local` aside to `.gaia/local.bak.<timestamp>` before linking the shared one. When the main checkout itself has no `frontend/.env`, linking skips it; copy `frontend/.env.example` to the main checkout's `frontend/.env` and link again, or, if `frontend/.env.example` is gone too, stop and ask the human to create `frontend/.env` (`frontend/app/env.server.ts` lists the required variables). Never read, print, or copy `.env` contents: the link shares the file without exposing it. The linked `.env` is the real one, so an `MSW_ENABLED` that is off sends Playwright to the real `API_URL`, exactly as in the main checkout.
7. **Dev smoke test**: `bash .gaia/scripts/dev-smoke.sh`: exit 0 means the route answered HTTP 200 and the server it started is stopped. It starts `pnpm -C frontend dev` on this tree's dev port, requests `/` (`--path` names another route), and stops only the server it started. Do not start or stop the dev server by hand for this step: a pattern kill (`pkill -f vite`, `kill $(lsof -ti:<port>)`) also stops other sessions' and other worktrees' servers. When the script refuses because the port is already in use, ask the user before stopping the holder; its header documents the exit codes.
8. `pnpm build` (`pnpm -C frontend build`): confirms production build.
9. **Fix all warnings before reporting**: never hand off with known warnings.
10. **Stop and report**: wait for user approval, except inside a workflow whose own instructions commit without stopping: the PR Merge Workflow's fix round ([[PR Merge Workflow#The fix round: fixer, verifier, gate]]), `/gaia-debt`, and a `/gaia-plan` orchestrator's phase commits.

| Step          | Result |
| ------------- | ------ |
| Simplify      | ...    |
| Localization  | ...    |
| Type checking | ...    |
| Linting       | ...    |
| Unit tests    | ...    |
| E2E tests     | ...    |
| Dev server    | ...    |
| Build         | ...    |

## When to skip the gate

Skip the gate entirely if no staged file is something typecheck / lint / tests / build can inspect. The gate runs only when at least one staged file matches:

- **Source**: `*.ts`, `*.tsx`, `*.js`, `*.jsx`, `*.mjs`, `*.cjs`, `*.css`
- **Gate-affecting config**: `package.json`, `pnpm-lock.yaml`, `tsconfig*.json`, `vite.config.*`, `vitest.config.*`, `playwright.config.*`, `eslint.config.*`, each at the repo root or directly under a package folder such as `frontend/`
- **Package registry**: `.gaia/packages.json` and `frontend/gaia.package.json`

Pure markdown, `.claude/**`, `wiki/**`, image, or other non-source-affecting commits skip straight to the commit step.

Quick check:

```bash
git diff --cached --name-only -z | tr '\0' '\n' | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|css)$|^([^/]+/)?(package\.json|pnpm-lock\.yaml|tsconfig.*\.json|vite\.config\.|vitest\.config\.|playwright\.config\.|eslint\.config\.)|^(\.gaia/packages\.json|frontend/gaia\.package\.json)$'
```

<!-- gaia:maintainer-only:start -->
Steps 3 to 8 check only the frontend package, so in this repo a match under `.gaia/cli/`, `.gaia/tests/`, or `.gaia/scripts/` does not select them: those paths belong to no registered package, which is also why `.gaia/scripts/precommit-packages.sh` runs no package check for them. Pipe the Quick check's output through the frontend filter and run steps 3 and 5 to 8 only when a path survives; when none does, step 4 runs only its `.gaia/cli/**` checks, and only when a `.gaia/cli/**` path is staged.

Frontend filter:

```bash
grep -vE '^\.gaia/(cli|tests|scripts)/'
```
<!-- gaia:maintainer-only:end -->

## Behavior when the gate runs

- **Fix issues as you encounter them** rather than just reporting them.
- All warnings/issues (typecheck errors, lint errors/warnings, test console warnings like missing i18n keys or HydrateFallback, runtime errors) must be resolved before the commit; never commit with known warnings.
- After fixing, **STOP and report results to the user**; do not commit until the user reviews and approves. That step governs an ordinary commit. Inside a workflow step 10 names, the commit proceeds on a clean gate: that workflow's own checkpoint is where the human reviews.

Localization: all user-facing strings must be localized; no hardcoded strings in JSX, no keys without values.

## Source of truth

This page is the source of truth for quality gate steps. The always-loaded `.claude/rules/quality-gate.md` rule points commits at this page.

See [[Pre-commit Hooks]], [[Workflow Doctrine]] (the gate runs once per commit, on the main thread), [[PR Merge Workflow]], [[Task Orchestration]], [[Claude Hooks]] (the source-edit and Bash safeguards keep `.env`, lockfile, secrets, and destructive-git footguns out of the staged surface before the gate ever runs).

<!-- gaia:maintainer-only:start -->
The Forensics Triage Workflow runs its own CI gate (`.github/forensics/run-quality-gate.sh`: install → typecheck → lint → test → knip) on every auto-fix branch; gate failure abandons the branch and demotes the issue to `needs-human` instead of opening a partial PR. That gate is distinct from the developer Quality Gate above: it adds `pnpm knip` because it runs post-task against a complete tree, whereas the dev gate omits knip (see `wiki/dependencies/knip.md`).
<!-- gaia:maintainer-only:end -->
