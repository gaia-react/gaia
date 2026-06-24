---
type: dependency
status: active
package: '@gaia-react/lint'
version: 1.5.1
role: lint-config
created: 2026-04-27
updated: 2026-06-24
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

## When to edit

- Edit `@gaia-react/lint` when the rule should propagate to **all** consumers.
- Edit GAIA's `eslint.config.mjs` only when the override is **GAIA-specific** (folder layout, app-only relaxations).

## See also

- [[ESLint Fixes]]
- [[Quality Gate]]
