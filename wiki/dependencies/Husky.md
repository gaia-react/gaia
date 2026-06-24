---
type: dependency
status: active
package: 'husky, lint-staged, is-ci'
version: '9.1.7, 17.0.7, 4.1.0'
role: pre-commit
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, ci]
---

# Husky + lint-staged

Pre-commit hooks. Configured by `pnpm prepare`: `is-ci` skips the `husky` setup in CI, then `prepare` runs `pnpm exec playwright install --with-deps` to provision Playwright browsers. The browser install runs in CI as well as locally, since `&&` follows the `is-ci || husky` group.

`.lintstagedrc.json` runs `eslint --fix`, `prettier --write`, and `stylelint --fix` against staged files. The `.husky/pre-commit` hook orchestrates the full gate: it runs `pnpm typecheck`, then `pnpm exec lint-staged`, then `pnpm test:lint-staged` (`vitest --run --changed --passWithNoTests --bail 1`).

The hook runs that sequence only when staged changes touch `app/`, `test/`, or `.storybook/`; otherwise it prints `No changed files -- skipping lint-staged` and exits. It also fails fast if more than one react-doctor config file exists at repo root, since react-doctor resolves the highest-precedence file and silently shadows the rest.

Running `vitest --run --changed` from the pre-commit hook catches regressions before they reach CI.

See [[Quality Gate]].
