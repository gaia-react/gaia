---
type: dependency
status: active
package: '@gaia-react/lint'
version: 1.11.0
role: lint-config
created: 2026-04-27
updated: 2026-07-22
tags: [dependency, lint, eslint]
---

# @gaia-react/lint

## What it is

GAIA's lint config, extracted to a standalone package under `github.com/gaia-react/lint`. The default export is the ESLint flat-config factory; the package also ships Prettier and Stylelint configs as the `@gaia-react/lint/prettier` and `@gaia-react/lint/stylelint` subpath exports (optional peer deps). The engine-neutral name supports a future Biome migration without consumer breakage.

## Why a separate repo

- Reuse across gaia-react org repos (gaia, create-gaia bootstrapper, branding, docs, future apps) without copy/paste drift.
- Single upgrade path: bump `@gaia-react/lint` instead of chasing 21 plugin upgrades per consumer.
- Engine swap freedom: name doesn't mention ESLint, so a v2 Biome backend is a non-breaking rename.

## Where rules live

Source of truth: `gaia-lint/src/configs/*.ts` (per export: `base.ts`, `react.ts`, `style-hygiene.ts`, `guardrails.ts`, `testing.ts`, `storybook.ts`, `playwright.ts`, `prettier.ts`, `better-tailwind.ts`, `ignores.ts`). Custom plugins (`no-enum`, `no-switch`, `no-jsx-iife`) live in `gaia-lint/src/plugins/`.

GAIA's `eslint.config.mjs` is a thin consumer: it spreads the package's exported arrays and adds GAIA-specific overrides last.

## Override pattern

The default export is a factory: call it once to get the config bundle, spread the bundle's arrays first, then add GAIA-specific overrides last (flat-config last-write-wins). `gaiaLint(opts?)` accepts `{sourceDir}` (default `'app'`) to scope file-path-based rules; pass `{sourceDir: 'src'}` when source lives elsewhere.

```js
import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

const lint = gaiaLint();

export default defineConfig([
  ...lint.ignores({extra: ['.gaia/**']}),
  ...lint.base,
  ...lint.react,
  ...lint.testing,
  ...lint.storybook,
  ...lint.playwright,
  ...lint.styleHygiene,
  ...lint.guardrails,
  ...lint.betterTailwind({entryPoint: './app/styles/tailwind.css'}),
  ...lint.prettier,
  // Project-specific overrides go LAST
  {
    files: ['app/some/path/**'],
    rules: {'some-rule': 'off'},
  },
]);
```

## Active rule groups

| Group | Key rules | Notes |
|---|---|---|
| `base` | Standard TS/JS hygiene | — |
| `react` | React-specific rules including `no-null-render` (autofix: converts `return null` in render context to `return undefined`; does not touch loaders, actions, or utilities) | `no-null-render` added in 1.8.0 |
| `testing` | D-8 test-honesty: `vitest/prefer-called-with`, `no-restricted-imports` (blocks `*.server` / internals from consumer tests) | Added in 1.6.0 |
| `storybook` | `eslint-plugin-storybook` recommended, scoped to `*.stories.*` and `.storybook/main.*` | `.storybook/` half reaches files from 1.11.0 |
| `playwright` | `eslint-plugin-playwright` recommended, scoped to `.playwright/**`; `expect-expect` counts `expect*()` helpers as the assertion, `no-skipped-test` allows the conditional `test.skip(condition, reason)` form | block reaches files from 1.11.0; `allowConditional` added there |
| `guardrails` | `no-enum`, `no-switch`, `no-jsx-iife`, `no-zod-enum` (errors on `z.enum([...])`; use `z.literal([...])` for string unions) custom plugins; `gaia/no-restricted-syntax` selectors ban `cond ? <JSX/> : null` and `cond ? null : <JSX/>` (flag-only, no autofix) and flag `.length && <JSX/>` numeric-0 leaks (report-only) | `.length` selector added in 1.8.0; `no-zod-enum` added in 1.9.0 |
| `styleHygiene` | `import-x/no-restricted-paths` with carve-outs: `resources+/` and `actions+/` routes are exempt for UI layers | Carve-out added in 1.6.0 |
| `betterTailwind` | Tailwind class ordering and hygiene | — |
| `prettier` | Formatting via Prettier as an ESLint rule | — |

The `resources+/` and `actions+/` carve-out means UI-layer files may import typed action/loader types from flat-file resource routes without an `eslint-disable` comment. Consumer tests must not import from `*.server` files or internal server surfaces; the `test/setup.ts` global Vitest setupFile is the single sanctioned place to start the MSW harness.

## When to edit

- Edit `@gaia-react/lint` when the rule should propagate to **all** consumers.
- Edit GAIA's `eslint.config.mjs` only when the override is **GAIA-specific** (folder layout, app-only relaxations).

## CLI consumer

`.gaia/cli` (`@gaia-react/cli`) is a second consumer, with its own `.gaia/cli/eslint.config.mjs` in its separate pnpm workspace. It consumes `base`/`react`/`testing`/`styleHygiene`/`guardrails`/`prettier` with `sourceDir: 'src'`, omitting the React-app-only presets (`storybook`, `playwright`, `betterTailwind`). It spreads `react` only because `base` transitively references `react/*` rules; the ruleset is inert on the CLI's non-JSX TypeScript. It disables a small Node/CLI set (`sonarjs/no-os-command-from-path`, `no-relative-import-paths`, `check-file/folder-match-with-fex`, `testing-library/render-result-naming-convention`) and extends the `unicorn/prevent-abbreviations` ignore list for CLI idioms. `.gaia/cli/eslint.config.mjs` is the source of truth for the full rule table.

## See also

- [[ESLint Fixes]]
- [[Quality Gate]]
