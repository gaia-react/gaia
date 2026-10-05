---
type: dependency
status: active
package: lint-staged
role: pre-commit
created: 2026-04-20
updated: 2026-10-05
tags: [dependency, ci]
---

# lint-staged

Runs the fixers against staged files only. `frontend/.lintstagedrc.json` runs `eslint --fix`, `prettier --write`, and `stylelint --fix` on the staged paths. lint-staged stashes the unstaged hunks, fixes the staged content, restores the hunks, and re-stages the fixes, so a partially staged file commits exactly the staged, fixed content and the working tree keeps the rest.

The pre-commit hook invokes it once per affected package, after `typecheck` and before `test:lint-staged` (`vitest --run --changed --passWithNoTests --bail 1`), which catches regressions before they reach CI (its browser projects need Chromium, see [[Testing]]). [[Pre-commit Hooks]] describes how the hook is installed and what it runs.

Playwright browser provisioning is a separate `pnpm install:browsers` script (`pnpm exec playwright install --with-deps`), run on demand by local developers; CI provisions browsers in its own dedicated workflow step.

See [[Quality Gate]].
